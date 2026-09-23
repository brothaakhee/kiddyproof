// kiddyproof-edge
//
// Observes the two requests that actually say something about installs, and
// writes one Analytics Engine datapoint per request. Nothing here changes
// what the app or the site does; the appcast is passed through byte-for-byte
// and the download is a plain redirect.
//
// Datapoint layout (queried by ../stats.sh — keep the two in sync):
//   index1  kind                 'heartbeat' | 'download'
//   blob1   kind                 (repeated so it can be selected as a column)
//   blob2   os                   macOS | iOS | iPadOS | Android | Windows | ChromeOS | Linux | other | none
//   blob3   isMac                '1' | '0'
//   blob4   bot                  '1' | '0'   heuristic, see looksLikeBot
//   blob5   src                  ?src= on /download (nav | hero | bottom)
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
const UA_MAX = 160;

// Sparkle formats its UA as "<bundle name>/<version> Sparkle/<sparkle version>".
const SPARKLE_UA = /^kiddyproof\/([\d.]+) Sparkle\//i;

const BOT_RE =
  /bot|crawl|spider|slurp|scan|monitor|fetch|curl|wget|python|go-http|java\/|okhttp|libwww|httpclient|headless|phantom|facebookexternalhit|twitterbot|slackbot|discordbot|whatsapp|telegram|preview|validator|archive/i;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    if (path === '/appcast.xml') return heartbeat(request, env, ctx);
    if (path === '/download' || path.startsWith('/download/')) return download(request, env, ctx, url);
    // Routes should never send anything else here; be a transparent proxy if they do.
    return fetch(request);
  },
};

async function heartbeat(request, env, ctx) {
  // Start the origin fetch before doing any bookkeeping so the app's update
  // check is never slower because of us.
  const origin = fetchOrigin(request, env);
  if (request.method === 'GET') ctx.waitUntil(record(env, request, { kind: 'heartbeat' }));
  return markEdge(await origin);
}

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
  const bytes = new TextEncoder().encode(`${env.HASH_PEPPER || ''}|${ip}|${ua}`);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].slice(0, 8).map((b) => b.toString(16).padStart(2, '0')).join('');
}
