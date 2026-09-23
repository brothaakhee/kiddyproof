// kiddyproof activation endpoint.
//
// A buyer finishes checkout on Creem and is sent here with ?checkout_id=. We
// look that checkout up server-side with our API key, confirm it is paid and
// for our product, then mint the key the APP actually understands: an
// Ed25519-signed `KIDDY.<payload>.<sig>` (see KiddyproofCore/License.swift).
// ?k= is the same exchange from the other end — a Creem store key pasted by
// someone who lost the success page.
//
// Why the exchange rather than teaching the app to speak Creem:
// everyone who already downloaded kiddyproof can buy and activate without
// updating, and the app keeps verifying offline with no phone-home.
//
// The signing key lives only in LICENSE_PRIVATE_KEY (Railway variable). It is
// the same key as secrets/license_private.key and must never be logged.

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const PORT = process.env.PORT || 3000;
const SEED_B64 = process.env.LICENSE_PRIVATE_KEY || '';
const CREEM_API_KEY = process.env.CREEM_API_KEY || '';
// Creem test keys are prefixed; pick the matching API host from the key itself
// so there is no second variable to forget when going live.
const CREEM_API_BASE = /test/i.test(CREEM_API_KEY)
  ? 'https://test-api.creem.io'
  : 'https://api.creem.io';
const EXPECTED_PRODUCT_ID = process.env.CREEM_PRODUCT_ID || '';
const SUPPORT_EMAIL = 'hello@kiddyproof.app';
const SUPPORT_X = 'brothaakhee';

// Anyone who reaches this page has already paid, so a dead end here is the
// worst possible moment. Every page carries a visible way to reach a human.
const HELP_BLOCK = `
      <div class="help">
        <p><strong>Stuck, or didn't get your key?</strong></p>
        <p>Email <a href="mailto:${SUPPORT_EMAIL}?subject=kiddyproof%20licence">${SUPPORT_EMAIL}</a>
           or DM <a href="https://x.com/${SUPPORT_X}" rel="noopener">@${SUPPORT_X}</a> on X.
           Both reach me directly — you've paid, so I'll make sure you get your licence.</p>
      </div>`;

// --- signing -----------------------------------------------------------

const { issueAppKey, privateKeyFromSeed, signingKeyStatus, canMint } = require('./license');

const privateKey = () => privateKeyFromSeed(SEED_B64);

// --- Creem --------------------------------------------------------------

// Creem hands us only a checkout_id on the return URL. We look the checkout up
// server-side with our API key, which is stronger than trusting a licence key
// in a query string: a checkout_id on its own is useless to anyone else.
async function fetchCreemCheckout(checkoutId) {
  const res = await fetch(
    `${CREEM_API_BASE}/v1/checkouts?checkout_id=${encodeURIComponent(checkoutId)}`,
    { headers: { 'x-api-key': CREEM_API_KEY, Accept: 'application/json' } }
  );
  if (res.status === 401) throw new Error('Creem rejected the API key');
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Creem responded ${res.status}`);
  return res.json();
}

// Consumes one activation against the order's Creem licence, which is how the
// per-licence issue cap is enforced. Returns {ok, usage, limit, error}.
// NOTE: this is a cap on how many times a key can be ISSUED, not on how many
// Macs it then runs on — the app verifies offline and counts nothing.
async function consumeCreemActivation(key, instanceName) {
  const res = await fetch(`${CREEM_API_BASE}/v1/licenses/activate`, {
    method: 'POST',
    headers: {
      'x-api-key': CREEM_API_KEY,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({ key, instance_name: instanceName }),
  });
  let body = null;
  try { body = await res.json(); } catch {}
  if (!res.ok) {
    // Creem's message is the only way to tell "wrong key" from "cap reached"
    // from "we sent the wrong shape" — log it verbatim.
    console.error('[activate] creem activate %s: %s', res.status, JSON.stringify(body));
  }
  // The activate response is FLAT: status / activation / activation_limit at
  // the top level, no license_key wrapper.
  return {
    ok: res.ok,
    status: body && body.status,
    usage: body && body.activation,
    limit: body && body.activation_limit,
    error: (body && (body.message || body.error)) || (res.ok ? null : `HTTP ${res.status}`),
  };
}

const licenceKeyOf = (checkout) => {
  const arr = checkout && (checkout.license_keys || checkout.licenses);
  const first = Array.isArray(arr) ? arr[0] : arr;
  return (first && (first.key || first.license_key)) || '';
};

// Redeeming a key straight from the customer's receipt or Creem portal.
// `validate` is deliberately NOT used: it requires an instance_id the customer
// does not have, and it returns no customer email either way. `activate` needs
// only the key, proves the key is real, and consumes one issue — the same
// budget the checkout path spends.
async function redeemCreemKey(key) {
  const act = await consumeCreemActivation(key, `kiddyproof ${new Date().toISOString().slice(0, 10)}`);
  return act;
}

const firstEmail = (checkout) =>
  (checkout && (checkout.customer?.email || checkout.order?.customer?.email)) || '';

const isPaid = (checkout) => {
  const status = String(checkout?.order?.status || checkout?.status || '').toLowerCase();
  return ['paid', 'completed', 'complete', 'succeeded', 'active'].includes(status);
};

const productIdOf = (checkout) =>
  String(checkout?.product?.id || checkout?.product || checkout?.order?.product || '');

// --- page --------------------------------------------------------------

const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])
  );

function page({ title, body, status = 200 }) {
  return {
    status,
    html: `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>${esc(title)}</title>
<meta name="robots" content="noindex" />
<style>
@font-face { font-family:'Fraunces'; font-style:normal; font-weight:300 600; font-display:swap;
  src:url('/fonts/fraunces-latin.woff2') format('woff2'); }
@font-face { font-family:'Hanken Grotesk'; font-style:normal; font-weight:300 700; font-display:swap;
  src:url('/fonts/hanken-grotesk-latin.woff2') format('woff2'); }
:root{ --night-0:#06070e; --ink:#edeef7; --ink-soft:#c4c8e0; --ink-mute:#8a90b4; --ink-dim:#5c6188;
  --gold:#ffe6a0; --amber:#ffc873; --cyan:#9ce0ff; --line:rgba(156,224,255,.10);
  --line-soft:rgba(255,255,255,.06); --ease:cubic-bezier(.22,1,.36,1); color-scheme:dark; }
*{box-sizing:border-box}
body{margin:0;min-height:100vh;padding:40px 20px 64px;
  background:radial-gradient(1100px 620px at 50% -10%,rgba(255,200,115,.10),transparent 62%),var(--night-0);
  color:var(--ink);font-family:'Hanken Grotesk',-apple-system,BlinkMacSystemFont,sans-serif;
  font-size:17px;line-height:1.65;display:flex;flex-direction:column;align-items:center}
a{color:var(--cyan)}
.wrap{width:100%;max-width:600px}
.card{background:linear-gradient(180deg,rgba(21,26,54,.72),rgba(10,12,24,.72));
  border:1px solid var(--line);border-radius:22px;padding:40px 34px;
  box-shadow:0 30px 80px rgba(0,0,0,.45)}
h1{font-family:'Fraunces',Georgia,serif;font-weight:600;font-size:clamp(26px,5.5vw,33px);
  line-height:1.15;margin:0 0 12px;text-align:center}
.sub{color:var(--ink-soft);text-align:center;margin:0 auto 26px;max-width:44ch}
.keybox{display:flex;gap:10px;align-items:stretch;margin:22px 0 10px}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:0.92em;
  color:var(--gold);white-space:nowrap}
.keybox code{flex:1;display:block;background:#05060c;border:1px solid var(--line);
  border-radius:12px;padding:14px 16px;font-size:13px;line-height:1.5;
  word-break:break-all;white-space:normal}
button{border:0;border-radius:12px;padding:0 18px;cursor:pointer;font-weight:700;font-size:15px;
  font-family:inherit;background:linear-gradient(180deg,var(--gold),var(--amber));color:#2a1c05}
button:active{transform:translateY(1px)}
ol{color:var(--ink-soft);padding-left:20px;margin:22px 0 0}
li{margin-bottom:8px}
.note{margin-top:24px;border-top:1px solid var(--line-soft);padding-top:18px;
  color:var(--ink-dim);font-size:14.5px}
.btn{display:inline-block;padding:16px 34px;border-radius:999px;
  background:linear-gradient(180deg,var(--gold),var(--amber));color:#2a1c05;
  font-weight:700;font-size:17px;text-decoration:none;
  box-shadow:0 10px 34px rgba(255,200,115,.22);
  transition:transform .25s var(--ease),box-shadow .25s var(--ease)}
.btn:hover{transform:translateY(-2px);box-shadow:0 16px 44px rgba(255,200,115,.30)}
details{margin-top:22px;border-top:1px solid var(--line-soft);padding-top:16px}
summary{cursor:pointer;color:var(--ink-mute);font-size:15px}
summary:hover{color:var(--ink-soft)}
.hint{text-align:center;color:var(--ink-dim);font-size:14.5px;margin:0}
.redeem{display:flex;gap:10px;margin:22px 0 6px;flex-wrap:wrap}
.redeem input{flex:1;min-width:260px;background:#05060c;border:1px solid var(--line);
  border-radius:12px;padding:14px 16px;color:var(--ink);font-size:15px;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.redeem input:focus{outline:none;border-color:var(--amber)}
.redeem .btn{padding:14px 26px;font-size:15px;border:0;cursor:pointer;font-family:inherit}
.help{margin-top:26px;border:1px solid rgba(255,200,115,.28);
  background:rgba(255,200,115,.06);border-radius:16px;padding:18px 20px;text-align:left}
.help p{margin:0;color:var(--ink-soft);font-size:15.5px;line-height:1.6}
.help p + p{margin-top:5px}
.help strong{color:var(--ink);display:block;margin-bottom:3px}
.help a{color:var(--amber);font-weight:600}
.foot{text-align:center;color:var(--ink-dim);font-size:14px;margin-top:24px}
.foot a{color:var(--ink-mute)}
</style>
</head>
<body>
<main class="wrap">
  <div class="card">${body}${HELP_BLOCK}</div>
</main>
</body>
</html>`,
  };
}

function successPage(appKey, email) {
  // The whole point: hand the key to the app over the kiddyproof:// scheme so
  // the buyer never copies anything. The manual key stays on the page, folded
  // away, for builds older than that scheme and for anyone the handoff fails.
  const deepLink = `kiddyproof://activate?key=${encodeURIComponent(appKey)}`;
  return page({
    title: 'Your kiddyproof license',
    body: `
      <h1>You're licensed.</h1>
      <p class="sub">Licensed to <strong>${esc(email)}</strong>. Opening kiddyproof to unlock it&hellip;</p>
      <p style="text-align:center;margin:26px 0 6px">
        <a class="btn" id="open" href="${esc(deepLink)}">Unlock kiddyproof</a>
      </p>
      <p class="hint" id="hint">If your Mac asks permission to open kiddyproof, allow it.</p>

      <details id="manual">
        <summary>kiddyproof didn't open?</summary>
        <p class="sub" style="text-align:left;margin:14px 0 0">
          Copy this key, then in kiddyproof: menu-bar icon &rarr; <strong>Enter License Key&hellip;</strong>
        </p>
        <div class="keybox">
          <code id="key">${esc(appKey)}</code>
          <button id="copy" type="button">Copy</button>
        </div>
      </details>

      <p class="note">This key is only shown here — it is <strong>not</strong> emailed to you.
      Bookmark this page (it re-issues your key any time) or copy the key somewhere safe.
      Lost it? Message me and I'll resend it.</p>
      <script>
        (function () {
          var link = ${JSON.stringify(deepLink)};
          // One automatic attempt, then let the button carry it. Browsers block
          // scheme navigation without a gesture often enough that the button is
          // the real path, not a fallback.
          //
          // This MUST wait for the document to finish parsing. Assigning
          // location.href while the parser is still running aborts it, and
          // every element after this script — including the help block — is
          // silently dropped from the page.
          function tryOpen() { try { window.location.href = link; } catch (e) {} }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', tryOpen);
          } else {
            tryOpen();
          }
          // If we're still here after a few seconds the handoff probably failed,
          // so surface the manual key rather than leaving them staring at it.
          setTimeout(function () {
            var d = document.getElementById('manual');
            if (d && !d.open) { d.open = true; }
            var h = document.getElementById('hint');
            if (h) { h.textContent = 'Still here? Use the key below \u2014 that always works.'; }
          }, 4000);
          document.getElementById('copy').addEventListener('click', async function () {
            var btn = this;
            try {
              await navigator.clipboard.writeText(document.getElementById('key').textContent.trim());
              btn.textContent = 'Copied';
            } catch (e) {
              var r = document.createRange();
              r.selectNodeContents(document.getElementById('key'));
              var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
              btn.textContent = 'Select + \u2318C';
            }
            setTimeout(function () { btn.textContent = 'Copy'; }, 2600);
          });
        })();
      </script>`,
  });
}

function problemPage(headline, detail, status) {
  return page({
    status,
    title: 'kiddyproof activation',
    body: `
      <h1>${esc(headline)}</h1>
      <p class="sub">${detail}</p>`,
  });
}

// --- server ------------------------------------------------------------

const FONT_DIR = path.join(__dirname, 'fonts');

const server = http.createServer(async (req, res) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  } catch {
    res.writeHead(400).end('bad request');
    return;
  }

  if (url.pathname === '/health') {
    // Report signing-key health without ever revealing it. This checks the key
    // actually PAIRS with the public key the shipped app verifies against, so a
    // wrong-but-well-formed key shows up here instead of in a customer's hands.
    const status = signingKeyStatus(SEED_B64);
    // Actually sign-and-verify a throwaway key so this reports what the
    // instance can DO, not just what it loaded. The key itself never leaves.
    const mintable = status === 'ok' && canMint(SEED_B64);
    const ok = status === 'ok' && mintable;
    res.writeHead(ok ? 200 : 500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      ok,
      signingKey: status,
      canMint: mintable,
      creemApiKey: CREEM_API_KEY ? 'set' : 'MISSING — purchases cannot be verified',
      creemApiBase: CREEM_API_BASE,
      productGuard: EXPECTED_PRODUCT_ID
        ? 'set'
        : 'UNSET — a purchase of any product in this Creem store would be accepted',
    }));
    return;
  }

  if (url.pathname.startsWith('/fonts/')) {
    const file = path.join(FONT_DIR, path.basename(url.pathname));
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404).end(); return; }
      res.writeHead(200, { 'Content-Type': 'font/woff2', 'Cache-Control': 'public, max-age=31536000, immutable' });
      res.end(data);
    });
    return;
  }

  if (url.pathname !== '/activate' && url.pathname !== '/') {
    res.writeHead(404, { 'Content-Type': 'text/plain' }).end('not found');
    return;
  }

  const send = ({ status, html }) => {
    res.writeHead(status, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'Referrer-Policy': 'no-referrer',
      'X-Content-Type-Options': 'nosniff',
    });
    res.end(html);
  };

  // Creem appends its own params to the return URL. Log the names so an
  // unexpected shape is visible here instead of surfacing as a vague error.
  const params = Object.fromEntries(url.searchParams.entries());
  console.log('[activate] return params:', Object.keys(params).join(',') || '(none)');

  if (!CREEM_API_KEY) {
    console.error('[activate] CREEM_API_KEY is not set — cannot verify purchases');
    send(problemPage(
      'Activation is not configured yet',
      `This one's on me, not you. Email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>
       with your order number and I'll send your key straight over.`,
      500));
    return;
  }

  const checkoutId = (params.checkout_id || params.checkoutId || '').trim();
  const directKey = (params.license_key || params.k || '').trim();

  if (!checkoutId && !directKey) {
    // Arriving here with nothing is the normal way a customer recovers: they
    // have the key from their receipt or the Creem portal but no activation
    // link. Give them somewhere to paste it rather than a dead end.
    send(page({
      title: 'Activate kiddyproof',
      body: `
      <h1>Activate kiddyproof</h1>
      <p class="sub">Paste the licence key from your receipt (or your Creem order page) and
      kiddyproof will unlock itself.</p>
      <form method="GET" action="/activate" class="redeem">
        <input type="text" name="k" autofocus autocapitalize="off" autocorrect="off"
               spellcheck="false" placeholder="XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
               aria-label="Licence key from your receipt" />
        <button class="btn" type="submit">Activate</button>
      </form>
      <p class="note">That's the short key that looks like <code>08P0U-E835X-…</code> &mdash; not the
      long one starting with KIDDY. Still have the link you landed on after paying? That works too.</p>`,
    }));
    return;
  }

  let email = '';

  if (checkoutId) {
    let checkout;
    try {
      checkout = await fetchCreemCheckout(checkoutId);
    } catch (err) {
      console.error('[activate] creem lookup failed:', err.message);
      send(problemPage(
        "Couldn't reach the store",
        `Your payment is safe. Please try this link again in a minute — if it keeps failing,
         email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.`,
        502));
      return;
    }

    if (!checkout) {
      send(problemPage(
        "We couldn't find that purchase",
        `Double-check you opened the most recent link from your receipt, or email
         <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> with your order number.`,
        404));
      return;
    }

    if (!isPaid(checkout)) {
      console.warn('[activate] checkout not paid:', checkout?.order?.status || checkout?.status);
      send(problemPage(
        'That payment has not completed',
        `If you've just paid, give it a moment and reload. If it still says this, email
         <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.`,
        402));
      return;
    }

    // Only ever mint keys for OUR product.
    if (EXPECTED_PRODUCT_ID && productIdOf(checkout) !== EXPECTED_PRODUCT_ID) {
      console.warn('[activate] product mismatch:', productIdOf(checkout));
      send(problemPage('That purchase is for a different product',
        `Email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> if this looks wrong.`, 403));
      return;
    }

    email = firstEmail(checkout);

    // Enforce the issue cap. A paying customer must never be stranded by a
    // schema surprise, so a missing licence key is logged loudly and allowed
    // through rather than treated as a failure.
    const creemKey = licenceKeyOf(checkout);
    if (!creemKey) {
      console.error('[activate] no licence key on checkout %s — issuing without consuming a slot', checkoutId);
    } else {
      let act;
      try {
        act = await consumeCreemActivation(creemKey, `kiddyproof ${new Date().toISOString().slice(0, 10)}`);
      } catch (err) {
        console.error('[activate] activation call failed:', err.message);
        act = { ok: true };   // never block a real purchase on our own outage
      }
      if (!act.ok) {
        const limit = act.limit != null ? act.limit : 'the maximum number of';
        console.warn('[activate] issue cap reached for checkout %s (%s/%s)', checkoutId, act.usage, act.limit);
        send(problemPage(
          "This licence has been issued its maximum number of times",
          `It has already been issued ${limit} times. If that wasn't you, or you simply need it
           again on a new Mac, message me using the details below and I'll reset it straight away —
           you bought it, you keep it.`,
          403));
        return;
      }
      if (act.usage != null && act.limit != null) {
        console.log('[activate] issue %s of %s for checkout %s', act.usage, act.limit, checkoutId);
      }
    }
  } else {
    // Someone pasted the key from their receipt or the Creem customer portal.
    let act;
    try {
      act = await redeemCreemKey(directKey);
    } catch (err) {
      console.error('[activate] creem redeem failed:', err.message);
      send(problemPage("Couldn't reach the store",
        `Please try again shortly, or message me using the details below.`, 502));
      return;
    }
    if (!act.ok) {
      console.warn('[activate] key rejected or exhausted:', act.error, act.usage, act.limit);
      send(problemPage("That key didn't work",
        `Check you copied the whole thing from your receipt. If it looks right, it may already have
         been issued its maximum number of times — message me below and I'll reset it.`, 400));
      return;
    }
    // Creem's licence endpoints never return the buyer's email, so the key is
    // labelled with the order's licence instead. It still ties the key to one
    // purchase, and it keeps a shared key from leaking anyone's address.
    email = `creem:${directKey}`;
    console.log('[activate] redeemed store key (%s of %s)', act.usage, act.limit);
  }

  if (!email) {
    console.error('[activate] no customer email on the verified purchase');
    send(problemPage("Couldn't read the purchase email",
      `Email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> and I'll issue your key by hand.`, 500));
    return;
  }

  let appKey;
  try {
    appKey = issueAppKey(email, SEED_B64);
  } catch (err) {
    console.error('[activate] signing failed:', err.message);
    send(problemPage("Couldn't generate your key",
      `This one's on me. Email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> and I'll send it over.`, 500));
    return;
  }

  console.log(`[activate] issued key for checkout ${checkoutId || '(direct key)'}`);
  send(successPage(appKey, email));
});

// Exported so the pages can be rendered and inspected without a real order.
module.exports = { successPage, problemPage, server };

if (require.main !== module) return;

server.listen(PORT, () => {
  console.log(`[activate] listening on ${PORT}`);
  const status = signingKeyStatus(SEED_B64);
  if (status === 'ok') console.log('[activate] signing key OK (matches the app\'s public key)');
  else console.error(`[activate] SIGNING KEY PROBLEM: ${status} — no keys can be issued`);
});
