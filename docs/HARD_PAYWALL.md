# Hard paywall — what this branch does, and what's left

Branch: `hard-paywall`. Model: **pay to get in, key-locked app.** No free trial.

The app already contained a working paywall — `AppController.armKidMode()` refuses
to arm and prompts for a license whenever entitlement is `.expired`. The trial was
the only thing keeping that gate open. So this branch flips a constant rather than
building anything new.

## The switch

`Sources/KiddyproofCore/License.swift`:

```swift
public static let trialDays = 0   // 0 = hard paywall; any N > 0 = N-day trial
```

`trialDaysLeft` returns `max(0, trialDays - used)`, so `0` means every unlicensed
launch resolves to `.expired` from the very first run. There is no separate
hard-paywall code path to maintain.

To revert: set it back to `3`, then undo the site copy in the commit. The test
`testShippedBuildHasPaywallEnabled` fails loudly if the constant changes without
the copy being revisited — that failure is the reminder, not a bug.

## Why the DMG barely changes

Enforcement lives in the **key**, not in the download. That means:

- The DMG can stay on the public GitHub releases repo — it is inert without a key.
- **Sparkle is completely untouched.** `appcast.xml`, the EdDSA signing in
  `Scripts/package.sh`, and the update flow all work exactly as before.
- No `SPUUpdaterDelegate`, no credentialed downloads, no re-signing.

The alternative model — gating the download and shipping an unlocked app — would
have required teaching Sparkle to authenticate its update fetches, because
`appcast.xml` is public and hardcodes the DMG URL. Anyone reading that XML would
get the app free. That path touches the most safety-critical code in the product
for strictly weaker enforcement, since one buyer could reshare the DMG.

## What changed here

**App (3 call sites + tests)**
- `License.swift` — `trialDays = 0`; added derived `offersTrial`; made `trialDays`
  an injectable parameter on `trialDaysLeft` / `entitlement` so tests cover both
  configurations regardless of what ships.
- `AppController.swift:471` — prompt no longer interpolates the trial length
  (would have read "Your 0-day free trial has ended").
- `LicenseManager.swift:55` — menu status reads "License required" rather than
  "Trial ended — license required".
- `LicenseTests.swift` — trial math now tested against an explicit `trialDays: 3`;
  added four hard-paywall cases. 37/37 pass.

**Site**
- All three download CTAs (nav, hero, bottom) now point at `/buy` and read
  "Get kiddyproof". No public DMG link remains in the markup.
- Trust line: "one-time license · 14-day refund · no account, no cloud".
- Analytics: the `download` event tracked `a[href*=".dmg"]`, which now matches
  nothing. Replaced with a `buy-intent` event on `a[href="/buy"]`, and the Meta
  custom event renamed `KiddyproofDownload` → `KiddyproofBuyIntent`.

**Legal**
- Terms: section 4 "Free Trial" removed, sections renumbered 5–18 → 4–17, and the
  cross-references updated (`Section 18` → `Section 17`; the survival clause to
  `Sections 3, 9, 11, 12, 13, 15 and 16`). Section 2 now states a key is required
  to operate. Section 5 states there is no trial and the 14-day refund stands in
  its place.
- Privacy: the first-launch-date row no longer says "determining remaining trial
  period".

## Before this can ship

1. **The buy page.** This branch forked from `main`, where `/buy` is still the old
   placeholder. It needs the real checkout from the payment-processor migration in
   flight. Merge order matters — take that work first, then rebase this.
2. **Activation UX.** `Info.plist` on the other branch registers
   `kiddyproof://activate?key=…`. With no trial, the gap between paying and a
   working app is the whole experience, so the post-checkout page should hand the
   key over automatically rather than asking anyone to paste it.
3. **Meta ad copy.** Any "free trial" hook needs rewriting, and the campaign's
   optimization event should move to the new `KiddyproofBuyIntent` / purchase
   event. The existing `KiddyproofDownload` conversions stop firing on merge.
4. **Update the appcast note only if you later gate downloads.** Nothing to do for
   this model.

## Expect the funnel to change shape

Roughly 1.66k visitors produced 15 tracked downloads under the trial model. Removing
the download step deletes that signal entirely: installs collapse, but every install
is a paying customer. Pre- and post-merge numbers are not comparable, so don't read
the drop as a regression. `/buy` needs its own analytics before this merges, or
there will be no funnel visibility at all.

## Optional, later: actually gating downloads

Not required for enforcement — the key already does that — but if "pay to download"
is wanted as positioning:

- Host the DMG privately (R2 or a Railway volume).
- Mint signed expiring URLs from the activation service, which already validates keys.
- Leave `appcast.xml` and Sparkle alone; updates only matter to people who have paid.

This is additive and touches no app code.
