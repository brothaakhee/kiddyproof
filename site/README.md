# kiddyproof — landing page

A single, self-contained marketing page for the kiddyproof macOS app.

**`index.html` is the canonical (and only) page** — dark theme: deep-night background,
"calm night, soft glow." The earlier light/white palette variants have been removed;
if a light theme is ever wanted again, derive it from `index.html` rather than
resurrecting the old copies (their markup and copy had drifted).

Everything (HTML + CSS + JS) is in one file. No build step, no external requests:
the two typefaces (Fraunces + Hanken Grotesk) are self-hosted as variable woff2
files in `fonts/` and declared via inline `@font-face` rules.

## Run locally

```sh
cd site
python3 -m http.server 8765
# open http://127.0.0.1:8765/index.html
```

Note: asset URLs are root-relative (`/fonts/…`, `/favicon.svg`), so serve from `site/`
as the web root rather than opening the file directly.

## What's inside

- **Aesthetic:** "calm night, soft glow" — deep-night palette with the app's real pastel orb
  colors (gold / amber / soft-white / cyan / rose), Apple-grade restraint.
- **Hero demo (the main attraction):** a *live* `<canvas>` running a faithful re-creation of
  the app's "Drift" scene over a faux-but-real-looking macOS desktop — drifting fireflies,
  blooms on every tap, a cursor that gathers the light, and a subtle cyan shield-edge shimmer
  when input is "caught." Glow sprites are pre-rendered once and blitted (no per-frame gradient
  allocation); the loop pauses when offscreen and has a single-RAF guard;
  `prefers-reduced-motion` shows a still frame. Visitors can move/click the canvas to interact.
- **Cat mascot:** an inline SVG (the "kiddy = kid + cat" play). Full detailed `#cat` for large
  placements (hero, CTA); a simplified `#cat-mark` (silhouette + calm eyes) for small nav/footer.
- **Sections:** hero → live demo → How it works → Effects gallery → "Why a cat?" → Safety
  (incl. an honest "Good to know" limitations block) → early-access CTA → footer.

## Notes

- Copy is scoped to what the app actually does (no OS/CPU overclaiming; "ordinary input"
  language matching the product's best-effort blocking; residual escapes — power button,
  Force Quit, accessibility shortcuts, multi-finger swipes, lid/idle lock, Secure Input,
  foreign-fullscreen visual gap — disclosed per `docs/ARCHITECTURE.md`).
- The primary action is **Get early access** (`mailto:hello@kiddyproof.app`) — swap to a real
  download URL / waitlist endpoint when a notarized build ships.
- Social sharing: OG/Twitter meta tags point at `https://kiddyproof.app/og.png` (1200×630).
- Accessibility: visible `:focus-visible` rings, `aria-hidden` on decorative SVGs/canvas,
  correct `h1→h2→h3` heading order, AA-contrast text, ≥44px primary tap target on mobile.
- Deploy: `deploy/public/` must mirror this directory (see `deploy/Caddyfile` for headers/CSP).
