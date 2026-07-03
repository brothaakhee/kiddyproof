# kiddyproof — landing page

A single, self-contained marketing page for the kiddyproof macOS app. Three palette variants
(pick one to ship — they share identical markup, copy, and the live canvas demo):

- **`index.html`** — **dark** theme: deep-night background, "calm night, soft glow."
- **`index-light.html`** — **light** theme: warm-paper (cream) background, dark ink, soft glow.
- **`index-white.html`** — **white / Apple** theme: pure-white pages, `#f5f5f7` panels,
  neutral grays, hairline borders, whisper-soft shadows, no grain, very faint ambient color.

In all three the demo window and effect tiles stay dark (they depict the app's own screen,
and the additive glow effects need a dark backdrop to read) — a dark product shot on a light
page is the classic Apple marketing look.

Everything (HTML + CSS + JS) is in one file each. No build step, no dependencies beyond two
Google Fonts (Fraunces + Hanken Grotesk) loaded via `<link>`.

## Run locally

```sh
cd site
python3 -m http.server 8765
# open http://127.0.0.1:8765/index.html        (dark)
# open http://127.0.0.1:8765/index-light.html  (light / cream)
# open http://127.0.0.1:8765/index-white.html  (white / Apple)
```

Or just open `index.html` directly in a browser (fonts need a network connection).

## What's inside

- **Aesthetic:** "calm night, soft glow" — deep-night palette with the app's real pastel orb
  colors (gold / amber / soft-white / cyan / rose), Apple-grade restraint.
- **Hero demo (the main attraction):** a *live* `<canvas>` that runs the app's "Drift" effect
  over a faux-but-real-looking macOS desktop — drifting fireflies, blooms on every tap, a
  cursor that gathers the light, and a subtle cyan shield-edge shimmer when input is "caught."
  Glow sprites are pre-rendered once and blitted (no per-frame gradient allocation); the loop
  pauses when offscreen and has a single-RAF guard; `prefers-reduced-motion` shows a still frame.
  Visitors can move/click the canvas to interact.
- **Cat mascot:** an inline SVG (the "kiddy = kid + cat" play). Full detailed `#cat` for large
  placements (hero, CTA); a simplified `#cat-mark` (silhouette + calm eyes) for small nav/footer.
- **Sections:** hero → live demo → How it works → Effects gallery → "Why a cat?" → Safety
  (incl. an honest "Good to know" scoping block) → early-access CTA → footer.

## Notes

- Copy is scoped to what the app actually does (no OS/CPU overclaiming; "ordinary input"
  language matching the product's own best-effort blocking; audio/limits disclosed honestly).
- The primary action is **Get early access** (mailto) — swap to a real download URL / waitlist
  endpoint when a notarized build ships. Update the `mailto:` address in the CTA.
- Accessibility: visible `:focus-visible` rings, `aria-hidden` on decorative SVGs/canvas,
  correct `h1→h2→h3` heading order, AA-contrast text, ≥44px primary tap target on mobile.
