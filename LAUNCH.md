# kiddyproof — Launch Kit

Everything needed to launch on Product Hunt and peer sites. Copy is written
per-platform (their cultures differ sharply). Live product: https://kiddyproof.app

---

## Core positioning (reuse everywhere)

**One-liner:** Hand your toddler the keyboard without losing your work.

**What it is:** A native macOS app. One shortcut drops a calm, glowing overlay
over your screen and swallows every keystroke, click, and scroll before it
reaches a single app — so a kid can mash away while your work stays exactly
where you left it. A deliberate 3-second parent gesture exits.

**Who it's for:** Parents who work on a Mac and hand it to a small child — the
call you can't drop, the email mid-sentence, the toddler who wants the laptop *now*.

**Why it's different:** Not a lock screen, not screen time controls. Your real
desktop stays visible and untouched; the child gets a soothing light-play world;
input is blocked at the system level, not hidden behind a password prompt.

**Proof/trust:** Developer-ID signed & Apple-notarized, an independent safety
watchdog that always returns control, refuses to run when it can't guarantee
safety, and an honest "things we can't protect you from" list on the site.

---

## Product Hunt

**Name:** kiddyproof

**Tagline (≤60 chars):** *(pick one)*
- Hand over the keyboard, keep your work (43)
- Toddler-proof your Mac in one shortcut (39)
- Let your kid mash the keyboard. Keep your work. (48)

**Topics:** Mac, Productivity, Parenting, Design Tools

**Description (≤260 chars):**
> One shortcut locks your Mac's keyboard and trackpad behind a calm, glowing
> overlay — your toddler mashes away in a world of light while your work stays
> untouched. A deliberate 3-second parent gesture exits. Signed, notarized, no
> account, no cloud.

**First comment (maker's comment — post immediately after launch):**
> Hey Product Hunt 👋
>
> I built kiddyproof after handing my laptop to my toddler one too many times
> and finding half an email deleted and three apps quit.
>
> Every "kid mode" I found either took over the whole Mac with a password lock,
> or was just an overlay you could click straight through. I wanted something
> that (a) actually blocks input at the system level, (b) keeps my real desktop
> visible so it never feels like a scary lockout, and (c) I could trust to hand
> control back if anything ever went wrong.
>
> So kiddyproof blocks every keystroke, click, and scroll before it reaches your
> apps, paints a calm firefly/ripple/constellation world on top (never
> overstimulating — that was a hard design rule), and exits only on a deliberate
> 3-second parent gesture. A separate watchdog process guarantees you always get
> control back. It's Developer-ID signed and Apple-notarized.
>
> It's honest about its edges, too — there's a literal "things we can't protect
> you from" list on the site (the power button, extremely clever children,
> spilled juice…).
>
> 7-day free trial, then a one-time license — no subscription, no account, no
> cloud. macOS 14+, Apple Silicon.
>
> I'd love your feedback, especially from other parents who work on a Mac. Happy
> to answer anything about how the input-blocking works under the hood.

**Gallery order:** 1) hero + tagline, 2) the live light-play demo, 3) the scene
gallery (calm scenes), 4) the 3-second exit gesture, 5) "things we can't protect
you from" (the charm/trust shot). Thumbnail: the cat/owl mark on deep-night.

**Launch timing:** Product Hunt day starts 12:01 AM PT. Post at 12:01 AM PT
(00:01 Pacific) for a full day of ranking. Tuesday–Thursday tends to be
strongest. Line up ~5–10 people to genuinely try it and comment in the first
few hours (no "upvote please" — PH penalizes that).

---

## Hacker News — Show HN

**Title:** Show HN: kiddyproof – block your Mac's keyboard so a toddler can't wreck your work

**Text (first comment / post body):**
> I'm a parent who works on a Mac, and handing it to my kid always ended with
> deleted text and quit apps. macOS parental controls are about screen time, not
> "let them bash the keyboard for two minutes without consequences."
>
> kiddyproof installs a suppressing CGEventTap (a session-level, head-insert
> tap with kCGEventTapOptionDefault) that swallows keyboard and pointer events
> before they reach any app. A transparent NSPanel at the shielding window level
> renders calm visuals driven by a summary of the swallowed events. Exit is a
> deliberate 3-second chord/corner hold — random mashing can't reproduce it.
>
> The part I cared most about is the failsafe: a separate, tap-free watchdog
> process holds a heartbeat and SIGKILLs the main app on livelock or timeout, so
> input is always restored even if the app itself wedges. It also refuses to arm
> while Secure Event Input is held (password fields, FileVault) rather than
> pretend it's protecting you, and it fail-loud disarms if the tap ever silently
> dies.
>
> Honest limits: it can't catch the hardware power button, a few OS-reserved
> shortcuts (Force Quit), or multi-finger trackpad gestures — those sit below
> where any non-root app can intercept. Not sandboxable, so it's a Developer-ID
> signed + notarized direct download, not a Mac App Store app.
>
> Tech: Swift, CoreGraphics for the effects, no dependencies beyond Sparkle.
> 7-day trial, one-time license, no account/telemetry. macOS 14+, Apple Silicon.
> Site + download: https://kiddyproof.app — happy to go deep on the event-tap
> and watchdog design in the comments.

*(HN values technical honesty and hates marketing speak. Lead with the mechanism,
disclose the limits up front, engage substantively.)*

---

## Reddit

Tailor per subreddit; never cross-post identical text. Post as a parent sharing
a tool, not an ad. Read each sub's self-promo rules first.

**r/macapps** (tool-friendly)
Title: `kiddyproof — I made a Mac app that blocks the keyboard so my toddler can't wreck my work`
Body: short origin story + what it does + honest limits + "7-day trial, one-time
license, no account." Link. Offer a few free licenses to the first commenters
who want to try it (great for goodwill + feedback).

**r/parenting / r/workingmoms / r/daddit** (lead with the parenting problem, not the tech)
Title: `I kept handing my laptop to my toddler and losing work — so I built a "kid mode" for the Mac`
Body: the relatable moment, how it helps, that it's calm-by-design and never
overstimulating. Mention it's a paid indie app up front (honesty) and that
you'd love parent feedback.

**r/SideProject / r/indiehackers** (the build story)
Title: `Launched kiddyproof: a notarized macOS "toddler lock" — 7-day trial, one-time license`
Body: the journey (input tap, watchdog, notarization, direct-download paywall),
metrics if any, ask for feedback.

---

## Other launch sites (submit to all — mostly free)

| Site | What it is | Notes |
|---|---|---|
| **BetaList** | Early-stage products | Good pre/post-launch audience; needs a short pitch + screenshot |
| **Uneed.best** | Daily product launches | PH-alternative, growing |
| **Fazier** | Launch platform | Free, decent traffic |
| **microlaunch.net** | Indie launches | Free |
| **Peerlist Launchpad** | Dev/maker audience | Good for indie macOS tools |
| **AlternativeTo** | Software alternatives | List as an alternative to macOS Screen Time / parental controls |
| **SaaSHub** | Software directory | Free listing |
| **Indie Hackers** | Product + story | Post a "milestone/launch" |
| **There's An AI For That / directories** | If any AI angle | N/A here — skip |
| **Hacker News** | Show HN | See above |
| **Product Hunt** | The main event | See above |
| **r/apple, r/macOS** | Only if allowed | Check rules; often no self-promo |

**Directory blurb (≤160 chars, reusable):**
> Toddler-proof your Mac: one shortcut blocks the keyboard and trackpad behind a
> calm light-play overlay while your work stays untouched. Signed & notarized.

---

## Asset checklist
- [ ] PH thumbnail 240×240 (owl/cat mark on deep-night) — from icon-512
- [ ] Gallery images 1270×760 (hero, demo, scenes, exit gesture, honest-limits)
- [ ] Optional: 30–60s screen-recording / GIF of a real session
- [ ] og.png (1200×630) already exists for link unfurls ✓

## Do-not-do
- No "please upvote" anywhere (PH/Reddit both penalize it).
- Don't cross-post identical Reddit text.
- Don't overstate protection — the honest-limits list is a feature, keep it.
