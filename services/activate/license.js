// Mints the keys the kiddyproof app understands:
// `KIDDY.<base64url payload>.<base64url Ed25519 signature>`, verified offline
// against the public key embedded in Sources/KiddyproofCore/License.swift.
// Kept separate from the server so it can be exercised on its own.

const crypto = require('node:crypto');

// The public key the shipped app verifies against — must stay identical to
// License.publicKeyB64 in Sources/KiddyproofCore/License.swift. A signing key
// that loads fine but is the WRONG key would mint plausible-looking keys the
// app silently rejects, so we check the pair matches rather than just that it
// parses.
const EXPECTED_PUBLIC_KEY = 'KD85xXx3dhShA3IZX1N5KgQJYxYZIWL65WNY0fFmliU=';

// Node cannot import a bare 32-byte Ed25519 seed; wrap it in the fixed PKCS#8
// prefix for Ed25519 private keys.
const PKCS8_ED25519_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

function privateKeyFromSeed(seedB64) {
  const seed = Buffer.from(seedB64 || '', 'base64');
  if (seed.length !== 32) {
    throw new Error('LICENSE_PRIVATE_KEY must be a base64-encoded 32-byte Ed25519 seed');
  }
  return crypto.createPrivateKey({
    key: Buffer.concat([PKCS8_ED25519_PREFIX, seed]),
    format: 'der',
    type: 'pkcs8',
  });
}

function publicKeyFor(seedB64) {
  const spki = crypto.createPublicKey(privateKeyFromSeed(seedB64))
    .export({ format: 'der', type: 'spki' });
  return spki.subarray(-32).toString('base64');
}

// 'ok' | 'missing or malformed' | 'wrong key'
function signingKeyStatus(seedB64) {
  let derived;
  try { derived = publicKeyFor(seedB64); } catch { return 'missing or malformed'; }
  return derived === EXPECTED_PUBLIC_KEY ? 'ok' : 'wrong key';
}

// SPKI wrapper for a raw 32-byte Ed25519 public key, so we can verify our own
// output with the same key the shipped app uses.
const SPKI_ED25519_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

const b64urlDecode = (s) =>
  Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');

// Signs a throwaway key and verifies it against EXPECTED_PUBLIC_KEY, proving
// this running instance can mint keys the app will accept. Returns only a
// boolean — the generated key is never exposed.
function canMint(seedB64) {
  try {
    const key = issueAppKey('self-test@kiddyproof.app', seedB64);
    const [prefix, payload, sig] = key.split('.');
    if (prefix !== 'KIDDY') return false;
    const pub = crypto.createPublicKey({
      key: Buffer.concat([SPKI_ED25519_PREFIX, Buffer.from(EXPECTED_PUBLIC_KEY, 'base64')]),
      format: 'der',
      type: 'spki',
    });
    return crypto.verify(null, b64urlDecode(payload), pub, b64urlDecode(sig));
  } catch {
    return false;
  }
}

const b64url = (buf) =>
  buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function issueAppKey(email, seedB64, today = new Date()) {
  const status = signingKeyStatus(seedB64);
  if (status !== 'ok') {
    // Refuse loudly rather than hand a customer a key the app won't accept.
    throw new Error(`signing key is ${status}`);
  }
  const payload = Buffer.from(
    JSON.stringify({ e: email, d: today.toISOString().slice(0, 10), p: 'pro' }),
    'utf8'
  );
  const sig = crypto.sign(null, payload, privateKeyFromSeed(seedB64));
  return `KIDDY.${b64url(payload)}.${b64url(sig)}`;
}

module.exports = { issueAppKey, privateKeyFromSeed, signingKeyStatus, canMint, EXPECTED_PUBLIC_KEY };
