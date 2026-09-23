// Throttle — a strongly consistent fixed-window counter, one Durable Object
// instance per key ("ip:<hash>" or "rcpt:<hash>").
//
// Why a Durable Object and not the Rate Limiting binding or KV: both of those
// are eventually consistent. In testing, the binding never returned a 429
// across 20 requests in five seconds, and KV let a second identical request
// through before the first one's write was readable. For an endpoint whose
// whole job is "send an email to whoever the caller names", the throttle has
// to be exact, and a DO's single-threaded storage is the primitive that makes
// it exact.
//
// Two operations, both POST with JSON { limit, periodSec }:
//   /take     count this request; reply { allowed, n }. Used before doing work.
//   /release  undo one count (the work failed and shouldn't consume the slot).
//
// Storage is one small object per key and an alarm clears it when the window
// closes, so idle keys cost nothing.

export class Throttle {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const { limit, periodSec } = await request.json();
    const now = Date.now();
    const periodMs = periodSec * 1000;

    let win = (await this.state.storage.get('win')) || null;
    if (!win || now - win.start >= periodMs) win = { start: now, n: 0 };

    if (url.pathname === '/release') {
      win.n = Math.max(0, win.n - 1);
      await this.state.storage.put('win', win);
      return Response.json({ n: win.n });
    }

    win.n += 1;
    await this.state.storage.put('win', win);
    if (win.n === 1) await this.state.storage.setAlarm(win.start + periodMs);
    return Response.json({ allowed: win.n <= limit, n: win.n });
  }

  async alarm() {
    await this.state.storage.delete('win');
  }
}

// Client helper for the Worker.
export async function throttle(env, key, op, limit, periodSec) {
  const stub = env.THROTTLE.get(env.THROTTLE.idFromName(key));
  const res = await stub.fetch(`https://throttle/${op}`, {
    method: 'POST',
    body: JSON.stringify({ limit, periodSec }),
  });
  return res.json();
}
