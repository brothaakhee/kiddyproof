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

**First comment (maker's comment — post right after launch, in my own voice):**
> hey everyone — i've got 2 little ones who are always attacking my computer,
> and they hate it when i try to navigate away from whatever they're poking at
> back to my actual work. so i built this thing.
>
> there are a few apps that kind of do this already, but what i like about
> mine is that the screen mainly just stays looking the way you left it — slack
> open, mid-message to your boss, all of it — while the kids can just go ham on
> the keyboard and trackpad and none of it actually lands. one shortcut turns
> it on, and getting out is a deliberate 3-second hold so they can't stumble
> out of it.
>
> it's mac only right now — haven't tried windows yet, but if enough people
> want it i'll probably do it. signed + notarized, 7-day free trial then a
> one-time license, no account or cloud stuff.
>
> would love feedback, especially from other parents who work on a mac. happy
> to get into how the input-blocking actually works too.

**Gallery order:** 1) hero + tagline, 2) the live light-play demo, 3) the scene
gallery (calm scenes), 4) the 3-second exit gesture, 5) "things we can't protect
you from" (the charm/trust shot). Thumbnail: the cat/owl mark on deep-night.

**Launch timing:** Product Hunt day starts 12:01 AM PT. Post at 12:01 AM PT
(00:01 Pacific) for a full day of ranking. Tuesday–Thursday tends to be
strongest. Line up ~5–10 people to genuinely try it and comment in the first
few hours (no "upvote please" — PH penalizes that).

---

## Hacker News — Show HN

**Title:** Show HN: kiddyproof – let your toddler bash the Mac keyboard without wrecking your work

**Text (post body):**
> i've got 2 little kids who are always grabbing at my laptop, and they hate it
> when i navigate away from whatever they were poking at back to my real work.
> so i built this.
>
> the idea: one shortcut and the screen basically stays looking exactly how you
> left it — slack open, half-written message and all — but every keystroke,
> click and scroll gets swallowed before it reaches any app. the kids can go
> ham and nothing actually lands. exit is a deliberate 3-second hold so they
> can't stumble out.
>
> under the hood it's a suppressing CGEventTap (session-level, head-insert,
> kCGEventTapOptionDefault) that eats keyboard and pointer events; a transparent
> shielding-level NSPanel paints the calm visuals on top. the part i cared most
> about is the failsafe — a separate watchdog process holds a heartbeat and
> SIGKILLs the app on any hang, so you always get control back. it also refuses
> to arm while Secure Event Input is held (password fields, FileVault) instead
> of pretending it's protecting you.
>
> honest limits: it can't catch the hardware power button, a couple OS-reserved
> shortcuts, or multi-finger trackpad gestures — those live below where any
> non-root app can intercept. it's not sandboxable, so it's a Developer-ID
> signed + notarized direct download, not a Mac App Store app.
>
> it's mac only right now — haven't tried windows, but if there's enough
> interest i'll probably build it. swift + coregraphics, no deps beyond sparkle.
> 7-day trial, one-time license, no account or telemetry. macOS 14+, apple
> silicon. https://kiddyproof.app — happy to go deep on the event-tap and
> watchdog stuff in the comments.

*(HN hates marketing speak — this leads with the personal reason and the
mechanism, discloses limits up front. Engage substantively in replies.)*

---

## Reddit

Tailor per subreddit; never cross-post identical text. Post as a parent sharing
a tool, not an ad. Read each sub's self-promo rules first.

**r/macapps** (tool-friendly)
Title: `i built a mac app that lets my toddlers bash the keyboard without wrecking my work`
Body:
> hey all — i've got 2 little ones who are always attacking my laptop, and they
> hate it when i try to navigate away from whatever they're poking at back to my
> actual work. so i built this thing.
>
> there are a few apps that kind of do this already, but what i like about mine
> is the screen mainly just stays looking the way you left it — slack open,
> mid-message to your boss, all of it — while the kids go ham on the keyboard
> and trackpad and none of it actually lands. one shortcut turns it on, getting
> out is a deliberate 3-second hold.
>
> mac only right now (haven't tried windows — if enough people want it i
> probably will). signed + notarized, 7-day free trial then a one-time license,
> no account or cloud stuff. site's at kiddyproof.app.
>
> happy to hand out a few free licenses to anyone who wants to try it and tell
> me what breaks.

**r/parenting** (lead with the parenting moment)
Title: `kept handing my laptop to my toddlers and losing work, so i made a "kid mode" for the mac`
Body:
> my two are always grabbing at my computer, and the second i try to get back to
> my own work they lose it. i wanted something where they could just mash away
> and i wouldn't have to worry about deleted emails or 15 apps quitting.
>
> so i made a little mac app: one shortcut and the whole keyboard/trackpad stops
> reaching anything, the screen stays looking exactly like i left it, and the
> kids get calm glowing stuff on top to poke at. calm on purpose — no flashing
> or loud noises. getting out is a 3-second hold so they can't do it by accident.
>
> it's a paid indie app (7-day free trial, one-time license — no subscription).
> mac only for now. would genuinely love feedback from other parents who work
> from a laptop. it's at kiddyproof.app if you want a look.

**r/SideProject** (the build story)
Title: `launched kiddyproof — a mac "toddler lock" that keeps your screen looking untouched`
Body:
> built this because my 2 kids kept attacking my laptop and wrecking my work.
> one shortcut swallows all keyboard/trackpad input before it hits any app, but
> the screen stays looking exactly how you left it (slack, half-typed message,
> whatever) — kids just get calm light to play with on top. exit is a deliberate
> 3-second hold.
>
> the fun/hard parts: a suppressing event tap for the input blocking, a separate
> watchdog process that guarantees you always get control back, and getting it
> Developer-ID signed + apple-notarized so it installs clean. sells direct with
> an offline license-key system (no server). mac only right now; windows maybe
> if there's interest.
>
> 7-day trial, one-time license. kiddyproof.app — feedback very welcome.

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
> a mac app that blocks the keyboard + trackpad so your kid can bash away
> without wrecking your work — the screen stays looking exactly how you left it.

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
