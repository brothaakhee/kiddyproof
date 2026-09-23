// kiddyproof-edge
//
// Three paths. Two are observed and passed through; one does work.
//
//   GET  /appcast.xml   Sparkle's daily check from every installed copy. Passed
//                       through byte-for-byte; one datapoint = an install heartbeat.
//   GET  /download*     The marketing download. Logged, then 302 to GitHub.
//   POST /send-link     A phone visitor's email address; we send them the
//                       download link. Throttled per IP and per recipient.
//
// Datapoint layout (queried by ../stats.sh — keep the two in sync):
//   index1  kind                 'heartbeat' | 'download' | 'send-link'
//   blob1   kind
//   blob2   os                   macOS | iOS | iPadOS | Android | Windows | ChromeOS | Linux | other | none
//   blob3   isMac                '1' | '0'
//   blob4   bot                  '1' | '0'   heuristic, see looksLikeBot
//   blob5   src                  ?src= on /download; for send-link: the page area, or 'error:<status>'
//   blob6   referrerHost
//   blob7   country              from Cloudflare
//   blob8   appVersion           parsed from the Sparkle user-agent
//   blob9   installId            peppered SHA-256 of ip + user-agent, first 16 hex
//   blob10  userAgent            truncated
//   blob11  asOrganization       from Cloudflare — datacenter ASNs flag bots
//   blob12  sparkle              '1' if the UA is Sparkle's exact shape
//   double1 1

const GITHUB_LATEST =
  'https://github.com/brothaakhee/kiddyproof-releases/releases/latest/download/kiddyproof.dmg';
const SITE = 'https://kiddyproof.app';
const UA_MAX = 160;

// Sparkle formats its UA as "<bundle name>/<version> Sparkle/<sparkle version>".
const SPARKLE_UA = /^kiddyproof\/([\d.]+) Sparkle\//i;

const BOT_RE =
  /bot|crawl|spider|slurp|scan|monitor|fetch|curl|wget|python|go-http|java\/|okhttp|libwww|httpclient|headless|phantom|facebookexternalhit|twitterbot|slackbot|discordbot|whatsapp|telegram|preview|validator|archive/i;

// Deliberately permissive: the provider does the real validation on send.
// This only keeps obvious garbage out of the rate limiter and the KV.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    if (path === '/appcast.xml') return heartbeat(request, env, ctx);
    if (path === '/download' || path.startsWith('/download/')) return download(request, env, ctx, url);
    if (path === '/send-link') return sendLink(request, env, ctx);
    // Routes should never send anything else here; be a transparent proxy if they do.
    return fetch(request);
  },
};

// ---------------------------------------------------------------- appcast

async function heartbeat(request, env, ctx) {
  // Start the origin fetch before doing any bookkeeping so the app's update
  // check is never slower because of us.
  const origin = fetchOrigin(request, env);
  if (request.method === 'GET') ctx.waitUntil(record(env, request, { kind: 'heartbeat' }));
  return markEdge(await origin);
}

// Only these reach the origin. Sparkle sends If-None-Match / If-Modified-Since
// so its daily check is a cheap 304 when nothing changed — those must survive.
// Everything else (Host, cf-*, x-forwarded-*) must not: Railway routes on Host,
// and under `wrangler dev` or workers.dev the incoming Host isn't the origin.
// Accept-Encoding is deliberately absent: the runtime decodes whatever the
// origin sends, so re-emitting the origin's Content-Encoding would mislabel
// the body. The appcast is a few KB; compressing it buys nothing.
const ORIGIN_HEADERS = [
  'user-agent', 'accept', 'accept-language',
  'if-none-match', 'if-modified-since',
];

function fetchOrigin(request, env) {
  const originUrl = new URL(request.url);
  originUrl.hostname = env.ORIGIN_HOST || 'kiddyproof.app';
  originUrl.protocol = 'https:';
  originUrl.port = '';
  const headers = new Headers();
  for (const h of ORIGIN_HEADERS) {
    const v = request.headers.get(h);
    if (v) headers.set(h, v);
  }
  return fetch(originUrl.toString(), { method: request.method, headers });
}

function markEdge(res) {
  const out = new Response(res.body, res);
  // The body we hold is already decoded; these two would describe the wire
  // form the origin used, not what we are sending.
  out.headers.delete('content-encoding');
  out.headers.delete('content-length');
  out.headers.set('X-Kp-Edge', '1');
  return out;
}

// --------------------------------------------------------------- download

async function download(request, env, ctx, url) {
  // HEAD and range requests are previews and sniffers, not downloads. GitHub
  // doesn't count them either, which keeps the two series comparable.
  if (request.method === 'GET' && !request.headers.has('range')) {
    ctx.waitUntil(record(env, request, { kind: 'download', src: url.searchParams.get('src') || '' }));
  }
  return new Response(null, {
    status: 302,
    headers: {
      Location: GITHUB_LATEST,
      'Cache-Control': 'no-store',
      'X-Kp-Edge': '1',
    },
  });
}

// -------------------------------------------------------------- send-link

async function sendLink(request, env, ctx) {
  if (request.method !== 'POST') return json({ ok: false, error: 'method' }, 405);
  // Not configured yet: tell the page so it can fall back to the mailto.
  if (!env.RESEND_API_KEY) return json({ ok: false, error: 'unavailable' }, 503);

  let body;
  try { body = await request.json(); } catch { return json({ ok: false, error: 'bad-request' }, 400); }

  // Honeypot: real browsers leave it empty. Pretend to succeed so the bot
  // learns nothing, and send nothing.
  if (body.hp) return json({ ok: true });

  const email = String(body.email || '').trim().toLowerCase();
  if (email.length > 254 || !EMAIL_RE.test(email)) return json({ ok: false, error: 'invalid-email' }, 400);

  // Per-IP: a handful a minute is plenty for a person, nothing for a script.
  if (env.SEND_LIMIT) {
    const ip = request.headers.get('cf-connecting-ip') || 'unknown';
    const { success } = await env.SEND_LIMIT.limit({ key: ip });
    if (!success) return json({ ok: false, error: 'rate-limited' }, 429);
  }

  // Per-recipient: one message per address per day, keyed by a peppered hash
  // so the KV never holds an address. This is what stops the endpoint being
  // used to pester someone.
  const recipientKey = 'sent:' + (await sha256hex(`${env.HASH_PEPPER || ''}|${email}`));
  if (env.SENT && (await env.SENT.get(recipientKey))) {
    return json({ ok: false, error: 'already-sent' });
  }

  const src = String(body.src || '').slice(0, 20);
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: env.FROM_ADDRESS || 'kiddyproof <hello@kiddyproof.app>',
      to: [email],
      reply_to: env.REPLY_TO || 'hello@kiddyproof.app',
      subject: 'Your kiddyproof download link',
      text: linkEmailText(),
      html: linkEmailHtml(),
    }),
  });

  if (!res.ok) {
    ctx.waitUntil(record(env, request, { kind: 'send-link', src: `error:${res.status}` }));
    return json({ ok: false, error: 'send-failed' }, 502);
  }

  if (env.SENT) ctx.waitUntil(env.SENT.put(recipientKey, '1', { expirationTtl: 86400 }));
  ctx.waitUntil(record(env, request, { kind: 'send-link', src }));
  return json({ ok: true });
}

// The link carries ?src=email so downloads that came from this message show up
// attributed in the download series.
const DOWNLOAD_FROM_EMAIL = `${SITE}/download?src=email`;

function linkEmailText() {
  return [
    'Here is the link to download kiddyproof for your Mac:',
    '',
    DOWNLOAD_FROM_EMAIL,
    '',
    'Open it on the Mac you want to install it on. kiddyproof needs macOS 14',
    'Sonoma or later on an Apple Silicon Mac.',
    '',
    'You asked for this link from kiddyproof.app. If that was not you, ignore',
    'this message — nothing else will be sent.',
    '',
    '— kiddyproof',
    SITE,
  ].join('\n');
}

function linkEmailHtml() {
  // Table layout and inline styles on purpose: this has to survive Gmail on iOS,
  // Apple Mail, and Outlook, none of which agree on anything else.
  return `<!doctype html>
<html><body style="margin:0;padding:0;background:#f5f5f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#1d1d1f;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f7;padding:32px 16px;"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:16px;padding:36px 32px;">
  <tr><td style="font-size:22px;font-weight:700;padding-bottom:12px;">Your kiddyproof download link</td></tr>
  <tr><td style="font-size:16px;line-height:1.55;color:#3a3a3c;padding-bottom:24px;">
    Open this on the Mac you want to install it on.
  </td></tr>
  <tr><td align="center" style="padding-bottom:28px;">
    <a href="${DOWNLOAD_FROM_EMAIL}" style="display:inline-block;background:#ffc873;color:#2a1c05;text-decoration:none;font-weight:700;font-size:16px;padding:14px 28px;border-radius:999px;">Download kiddyproof for macOS</a>
  </td></tr>
  <tr><td style="font-size:14px;line-height:1.55;color:#6e6e73;padding-bottom:20px;">
    Needs macOS 14 Sonoma or later on an Apple Silicon Mac.<br>
    If the button doesn't work, copy this link:<br>
    <a href="${DOWNLOAD_FROM_EMAIL}" style="color:#0071e3;">${DOWNLOAD_FROM_EMAIL}</a>
  </td></tr>
  <tr><td style="font-size:12px;line-height:1.5;color:#a1a1a6;border-top:1px solid #e5e5ea;padding-top:16px;">
    You asked for this link from kiddyproof.app. If that wasn't you, ignore this message — nothing else will be sent.
  </td></tr>
</table>
</td></tr></table>
</body></html>`;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Kp-Edge': '1' },
  });
}

// ---------------------------------------------------------------- record

async function record(env, request, extra) {
  if (!env.STATS) return; // no binding under local dev

  const ua = request.headers.get('user-agent') || '';
  const cf = request.cf || {};
  const sparkleMatch = ua.match(SPARKLE_UA);
  const sparkle = !!sparkleMatch;
  const version = sparkleMatch ? sparkleMatch[1] : '';
  const os = sparkle ? 'macOS' : detectOS(ua);
  const bot = !sparkle && looksLikeBot(ua);
  const installId = await installHash(request, ua, env);

  env.STATS.writeDataPoint({
    indexes: [extra.kind],
    blobs: [
      extra.kind,
      os,
      os === 'macOS' ? '1' : '0',
      bot ? '1' : '0',
      extra.src || '',
      hostOf(request.headers.get('referer')),
      cf.country || '',
      version,
      installId,
      ua.slice(0, UA_MAX),
      String(cf.asOrganization || '').slice(0, 60),
      sparkle ? '1' : '0',
    ],
    doubles: [1],
  });
}

function detectOS(ua) {
  // Order matters: Android UAs contain "Linux", iPad desktop-mode UAs say
  // "Macintosh". Mobile checks go first; the iPad-as-Mac case is only
  // separable client-side (touch points), so it lands in macOS here.
  if (/iPhone|iPod/.test(ua)) return 'iOS';
  if (/iPad/.test(ua)) return 'iPadOS';
  if (/Android/.test(ua)) return 'Android';
  if (/Windows/.test(ua)) return 'Windows';
  if (/CrOS/.test(ua)) return 'ChromeOS';
  if (/Macintosh|Mac OS X/.test(ua)) return 'macOS';
  if (/Linux|X11/.test(ua)) return 'Linux';
  return ua ? 'other' : 'none';
}

function looksLikeBot(ua) {
  return !ua || BOT_RE.test(ua);
}

function hostOf(referer) {
  if (!referer) return '';
  try { return new URL(referer).hostname; } catch { return ''; }
}

async function installHash(request, ua, env) {
  // Pseudonymous, not reversible: the pepper is a Worker secret, so the
  // dataset never holds anything an IP can be recovered from.
  const ip = request.headers.get('cf-connecting-ip') || '';
  return (await sha256hex(`${env.HASH_PEPPER || ''}|${ip}|${ua}`)).slice(0, 16);
}

async function sha256hex(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
