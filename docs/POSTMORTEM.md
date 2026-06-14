# SoundCtl — Development Post-Mortem

A retrospective of building SoundCtl (a macOS 26 menu-bar Sound popover replica
that also controls external-monitor volume over DDC, plus hardware-volume-key
and scroll control). The goal here is not to celebrate the result — it works and
is hardened — but to be brutally honest about **where time was lost** and **how
the same outcome could have been reached with far less back-and-forth**, with
concrete, reusable guidance for both sides of the collaboration.

> TL;DR: ~80% of the *iteration* time went into four avoidable sinks: (1) trial-
> and-error on the window/material architecture, (2) a **misdiagnosed** "knob
> border" that triggered a whole throwaway two-window architecture, (3) **pixel
> tuning by screenshot round-trips**, and (4) the **ad-hoc-signing permission
> churn** that forced ~6 re-grants and wasn't root-caused until the very end. All
> four were preventable with earlier structure.

---

## 1. What we built (the outcome)

A lean Swift Package (no Xcode): AppKit shell + SwiftUI popover on real Liquid
Glass, CoreAudio device handling, DDC/CI volume via the private `IOAVService`,
a `CGEventTap` for the hardware volume keys with an on-screen HUD, scroll-to-
adjust, a functional right-click menu, 50 in-process self-tests, and a stable
self-signed code-signing identity so the Accessibility grant persists. Published
to GitHub, hardened against an adversarial code review.

The *destination* was reasonable and mostly well-chosen. The *path* wandered.

---

## 2. Timeline — every phase, summarized

| # | Phase | What happened | Net assessment |
|---|-------|---------------|----------------|
| 1 | **Framing** | "Why is the LG volume greyed out?" → explained digital passthrough → decided to build a replica that drives DDC. | Efficient. Good problem framing. |
| 2 | **Scaffold + core** | SPM lib/exec/C-shim, CoreAudio enumeration/switching, DDC read/write (verified 25%→25% on the LG). | Efficient. The early end-to-end DDC proof was the right first milestone. |
| 3 | **Popover v1 + functional fixes** | Replicated legacy popover; fixed a layout collapse; filtered virtual devices (Teams Audio) via `kAudioDevicePropertyDeviceCanBeDefaultDevice`; ordered devices; dynamic menu-bar icon; click-to-step. | Mostly efficient; driven by clear functional requirements. |
| 4 | **Container/material churn** | NSPopover → borderless panel → NSMenu → manual `popUp` → panel → NSMenu → **key panel** → NSGlassEffectView. Repeated pivots chasing the right translucency/material and an "active blue" slider. | **Big sink.** Pure trial-and-error against undocumented macOS rendering behavior. |
| 5 | **Transparency saga** | "too opaque" → discovered `maskImage` breaks vibrancy → `.menu` vs `.popover` material → only system containers gave the real material. | Sink. Same root: guessing at material rendering. |
| 6 | **Slider saga** | knob translucency-on-drag, fill colors, "gets stuck" on fast drag, switched to native `NSSlider`, then it rendered **grey in NSMenu**, then **key window** needed for active fill. | Sink, but produced a real insight (non-key windows render controls inactive). |
| 7 | **"Perfect forgery" pixel tuning** | Many rounds of "fonts/icons/spacing/thickness still off," measured against user screenshots with PIL. | **Big sink** — inherently iterative, but done one delta at a time. |
| 8 | **Liquid Glass research tangent** | `web_search` hallucinated an API; verified against the SDK header instead; a side conversation about the tool's origins. | Minor sink + a useful lesson (verify against the SDK, not synthesized web answers). |
| 9 | **HelloKnob prototype (user's idea)** | A separate sample app to test *native* knobs/sliders; a control palette; material comparison; the knob-border investigation; two-window glass; the empty-canvas-on-reopen bug; settled on **single glass window + `focusEffectDisabled`**. | **Inflection point.** The prototype was the single best decision — but it arrived in phase 9, not phase 4. |
| 10 | **Knob-border misdiagnosis** | Believed the border was Liquid-Glass styling/vibrancy. Tried `allowsVibrancy`, then built a **two-window architecture**. Screenshot pixel analysis finally showed it was the **keyboard focus ring**; fixed with `.focusEffectDisabled()`; the two-window code (and its empty-canvas bug) was then deleted. | **The most expensive detour.** A whole architecture built on an unverified hypothesis. |
| 11 | **Port prototype → app** | Replaced AppKit popover body with the validated SwiftUI; rewired controllers. | Efficient once the recipe was proven. |
| 12 | **Visual micro-tuning** | Output header font (O6), settings padding, flank color `#384057` then a dynamic dark-mode variant, unselected-glyph color (**wrong-variable detour**: changed the circle when you meant the glyph; changed the dark branch while you were viewing light mode), notched MacBook icon, headphones menu-bar icon + size match. | Sink — several detours from element/mode ambiguity and multi-monitor screenshots. |
| 13 | **Right-click menu** | Native visibility options → realized they were nonsensical for a single-entry agent → reduced to **Launch at Login + Quit**; fixed the auto-persisted `isVisible` hiding the icon. | Efficient; good "make it make sense" course-correction. |
| 14 | **Publish** | Public GitHub repo, MIT, releases. | Efficient. |
| 15 | **Hardware volume keys** | `CGEventTap`, HUD, BetterDisplay deferral, non-linear step grid. Then the **Accessibility permission saga**: ~6 re-grants because each reinstall (ad-hoc) wiped TCC. | **Big sink** — the re-grant churn dominated. |
| 16 | **Scroll-to-adjust** | Over the popover, then over the menu-bar icon; suppress HUD when popover open. | Efficient. |
| 17 | **Menu-bar icon animation** | Attempted a smooth wave-fill; it read as a snap / regressed; **reverted**. | Sink — chasing a polish the status-item API can't deliver well. |
| 18 | **Adversarial review** | 20-question brutal review → fixed all legitimate findings (async DDC I/O was a genuine ship-blocker) → verified by a second review. | **High value.** Should have been run *periodically*, not once at the end. |
| 19 | **Signing root-cause fix** | Finally fixed the permission churn with a stable self-signed identity; proved the grant persists across reinstalls. | The right fix — ~15 turns too late. |

---

## 3. The four big time-sinks, root-caused

### A. Architecture trial-and-error (phases 4–6)
We discovered macOS rendering rules empirically, in the *production* app, one
pivot at a time: which container yields the real material, why a slider renders
grey, why vibrancy needs a key window. Every wrong guess meant a rebuild + visual
check.

**Why it was slow:** the production app is a bad lab — too much surrounding code,
and each test is a full build/relaunch.

### B. The knob-border misdiagnosis (phase 10)
This is the single most instructive failure. The symptom ("knob has a border")
was attributed to the glass material. A **two-window architecture** was designed,
built, and shipped to fix it — and it introduced its own bug (empty canvas on
reopen). Only when the popover was screenshotted and pixels were compared did it
become clear: it was the **keyboard focus ring**, removable with one modifier.

**Why it was slow:** we acted on a *plausible* hypothesis instead of *verifying*
the root cause first. The cost wasn't one wrong fix — it was an entire
architecture and a derivative bug.

### C. Pixel tuning by round-trip (phases 7, 12)
"Still too light / too thick / wrong size" → change one value → reinstall →
screenshot → repeat. Correct but serial, and several iterations were spent on
**ambiguity** (which element, which appearance mode) rather than the actual
pixels.

### D. The ad-hoc-signing permission churn (phases 15, 19)
The volume-key Accessibility grant reset on **every** reinstall because ad-hoc
signatures have a `cdhash`-based designated requirement that changes each build.
We re-granted ~6 times, repeatedly re-diagnosed "is it the OS or the
permission?", and I even **abandoned** a stable-signing setup midway over a
fixable `openssl`/PKCS12 issue. The permanent fix (a stable self-signed identity
→ cert-based, build-invariant requirement) was a ~30-minute job that, done in
phase 15, would have erased a dozen frustrating turns.

---

## 4. What *worked* (keep doing this)

- **End-to-end DDC proof first** (phase 2) — de-risked the core unknown immediately.
- **The HelloKnob prototype** — isolating the rendering questions in a tiny app
  was decisive; it just came too late.
- **In-process self-tests + debug flags** (`--self-test`, `--debug-popover`,
  `--debug-hud`, `--ddc-test`) and **PIL pixel measurement** — fast, objective
  verification without a human in the loop.
- **The adversarial review** — found a real ship-blocker (main-thread DDC I/O)
  that no amount of "looks right" would have caught.
- **Course-correcting on product sense** (gutting the nonsensical right-click
  menu) instead of slavishly copying native.

---

## 5. How *you* (the user) could drive faster convergence

You guided well overall — clear intent, good instincts (the prototype idea was
yours), and honest feedback. The friction was rarely about effort; it was about
**information arriving late** and **corrections being ambiguous**. Concretely:

1. **Front-load the reference material and exact specs.** Drop the native
   screenshot *and* the target numbers you already know (colors like `#384057`,
   sizes, the step grid 2/5/10) at the *start* of the visual phase, not as
   reactions. Every spec discovered mid-stream cost a full round-trip.

2. **Name the element and the mode in every correction.** "Make it darker"
   cost two wrong attempts; "the *speaker glyph* (not the circle), in *dark
   mode*" would have cost zero. When a screenshot is involved, say which app is
   which and which appearance you're in (one detour came from a screenshot
   captured mid light/dark switch).

3. **Declare environment constraints up front.** Multi-monitor (caused repeated
   screenshot misses), your dark/light preference, and whether BetterDisplay is
   running — all produced detours because they surfaced late.

4. **Suggest the sandbox earlier for risky unknowns.** Your "let's try it in a
   hello-knob sample" was the highest-leverage instruction in the whole project.
   The heuristic: *if a question is "how does macOS actually render X," demand a
   throwaway prototype before touching the real app.*

5. **Escalate recurring pain into a "fix the root cause" directive.** After the
   2nd or 3rd Accessibility re-grant, "stop re-granting — make this persist
   permanently" would have triggered the signing fix ~10 turns earlier. A good
   signal to me is: *"this is the Nth time we've hit this; treat it as a bug,
   not a chore."*

6. **Batch visual tweaks.** Each one-line change forced a reinstall (which broke
   the grant). "Here are five tweaks: …" would have collapsed five reinstall +
   re-grant cycles into one.

7. **Make architecture tradeoffs explicit when you spot them.** E.g. accepting
   app-activation to get the native blue slider — a one-line "I'm fine with the
   focus-steal for the correct look" pre-empts a tradeoff discussion.

---

## 6. How *I* (the agent) should have done better

- **Build the isolated prototype for any "how does macOS render this" question
  *before* writing production code.** I reached for the prototype only when you
  suggested it (phase 9). It should have been my phase-4 reflex.
- **Verify root cause empirically before architecting.** I built a two-window
  system on a *hypothesis* about the knob border. The 10-minute screenshot/pixel
  test that finally found the focus ring should have been step one, not step N.
- **Fix systemic friction the first time it bites.** The permission reset was a
  *system* problem (signing), not a per-incident chore. I treated it as the
  latter for far too long and even abandoned the correct fix over a trivial
  `openssl` flag. Rule: *if the same manual step recurs ≥2×, automate or
  eliminate it before continuing.*
- **Confirm the target before mutating it.** A one-word "the glyph or the
  circle?" would have avoided the wrong-variable changes.
- **Handle multi-display capture deterministically from the start** (offscreen
  bitmap render, or capture every display) instead of repeatedly missing the
  window.
- **Don't reinstall for popover-only changes** — those need no permission, so the
  grant-breaking reinstall was self-inflicted churn.
- **Run the adversarial review at milestones,** not once at the end — the
  main-thread-I/O ship-blocker existed for many phases before it was caught.

---

## 7. The optimized playbook (same outcome, ~half the turns)

If we restarted with everything we now know:

1. **Spike (1 session):** prove DDC read/write on the LG end-to-end. *(we did this)*
2. **Rendering lab first:** a HelloKnob-style prototype that answers, up front
   and in isolation: which window/material gives the native Liquid Glass; that a
   **single `NSGlassEffectView` key window + `focusEffectDisabled` native
   `Slider`** is the recipe (clean knob, blue fill, real material). *Outcome:
   skips phases 4–6 and 10 entirely.*
3. **Spec sheet:** you hand over the native screenshot + known colors/sizes/step
   grid once. Tune against it in **batched** passes with element/mode named.
   *Outcome: collapses phases 7 and 12.*
4. **Stable signing on day one:** `setup-signing.sh` before the first install.
   *Outcome: zero re-grants for the entire project.*
5. **Build the app** on the proven recipe; wire CoreAudio/DDC; add the keys/
   HUD/scroll. Run the **adversarial review at each milestone**, not just the end.
6. **Publish.**

Net: the destination is identical; the wandering — material churn, the two-window
detour, the pixel ping-pong, and the permission churn — largely disappears.

---

## 8. The single most transferable lesson

> **Verify before you architect, and isolate before you guess.** The two worst
> sinks (the knob-border two-window detour and the signing churn) shared one
> cause: acting on a plausible story instead of cheaply *proving* the real one.
> A throwaway prototype and a 10-minute root-cause check are almost always
> cheaper than the architecture you'd build on a wrong assumption.
