# SoundCtl — Development Post-Mortem

A retrospective on building SoundCtl (a macOS 26 menu-bar Sound popover replica
that also drives external-monitor volume over DDC, plus hardware-volume-key and
scroll control). The purpose is not to celebrate the result — it works and is
hardened — but to attribute, **fairly and with evidence**, where iteration time
was lost and how the same outcome could have been reached with far less
back-and-forth.

## 0. A note on integrity (and a correction)

An earlier draft of this document recommended that the *user* should have
"front-loaded the reference material and exact specs." That was wrong on two
counts, and it is worth stating plainly because the rest of this analysis only
has value if its attribution is honest:

1. **The user did share reference screenshots early and repeatedly.** The visual
   target was available; it was not withheld.
2. **The biggest time-sinks were in a domain the user is not expected to know.**
   The user is the *requester/owner* of the product, not a macOS rendering
   engineer. Asking them to pre-specify window classes, vibrancy/material
   behavior, or focus-ring semantics is asking them to supply expert knowledge
   that is, by definition, **the agent's job to possess or to discover**. When
   the agent "went in circles" on materials, the user could not have steered —
   not through any fault of theirs, but because the unknown lived on the agent's
   side of the table.

That first-draft error — an implementer reflexively shifting an implementer-
domain failure onto the customer — is itself one of the most important lessons
here, so this version leads with a responsibility model and applies it
consistently.

---

## 1. The lens: who is responsible for what

Distinguishing this cleanly is what makes the rest of the analysis fair.

| Responsibility | Owner | Examples in this project |
|---|---|---|
| **Intent & acceptance** ("make it look/behave like the native control"; "good enough / not yet") | **User** | All the "not even close yet, for a forgery" feedback. |
| **Reference of the desired result** (what it should look like) | **User** | The native screenshots, shared early and throughout. |
| **Subjective product decisions** (which option, when a tradeoff is surfaced) | **User** | "keep the native pill"; gutting the right-click menu. |
| **Facts the user possesses about their environment** | **User** | Multi-monitor, current light/dark mode, whether BetterDisplay is running. |
| **Precision of a correction** (which element, which state) | **Shared** | "the *glyph*, not the circle"; "I'm in *light* mode now." |
| **Expert implementation knowledge** (macOS APIs, materials, window/event semantics) | **Agent** | Which container yields Liquid Glass; why a control renders grey; what the knob "border" actually is. |
| **A method for resolving unknowns cheaply** (prototyping, root-cause verification, automating recurring friction) | **Agent** | Should have been applied to materials, the knob border, and signing. |

The headline finding, applying this lens: **the large sinks were agent-owned.
The user's guidance was appropriate for a non-expert domain owner, and was, on
the whole, good.**

---

## 2. Timeline — every phase, with honest attribution

| # | Phase | Summary | Net | Owner of the cost |
|---|-------|---------|-----|-------------------|
| 1 | Framing | "Why is the LG volume greyed?" → digital passthrough → build a DDC-driven replica. | Efficient | — |
| 2 | Scaffold + core | SPM lib/exec/C-shim; CoreAudio; DDC verified end-to-end (25%→25% on the LG). | Efficient | — (good de-risking) |
| 3 | Popover v1 + functional fixes | Legacy popover; layout-collapse fix; virtual-device filtering (Teams Audio); device ordering; dynamic menu-bar icon; click-to-step. | Efficient | — |
| 4 | **Window/material churn** | NSPopover → panel → NSMenu → manual popUp → panel → NSMenu → key panel → NSGlassEffectView, chasing the real translucency and an active-blue slider. | **Large sink** | **Agent.** macOS-rendering expertise; the user cannot specify what they don't know, and the agent lacked both the knowledge and a discovery method. |
| 5 | Transparency saga | `maskImage` breaks vibrancy; `.menu` vs `.popover`; only system containers gave the real material. | Sink | **Agent** (same root). |
| 6 | Slider saga | knob-on-drag, fill colors, "gets stuck", native `NSSlider`, grey-in-NSMenu, key-window needed for active fill. | Sink (with a real insight) | **Agent** for the thrash; the *insight* (non-key windows render controls inactive) was legitimately hard-won. |
| 7 | "Perfect forgery" pixel tuning | Many rounds of fonts/icons/spacing/thickness vs. the user's screenshots (measured with PIL). | Sink (partly inherent) | **Mostly inherent** to iterative visual matching; a slice was agent-side (serial, not batched) and a slice was avoidable ambiguity (see #12). |
| 8 | Liquid Glass research tangent | `web_search` hallucinated an API; verified against the SDK header instead. | Minor sink + good lesson | **Agent** (should have gone to the SDK first). |
| 9 | **HelloKnob prototype (user's idea)** | A throwaway sample to test native knobs/sliders in isolation; control palette; material comparison; settled on a **single `NSGlassEffectView` key window + `focusEffectDisabled` native `Slider`**. | **Inflection point** | **Credit: user** for proposing isolation. **Agent** for not having done it in phase 4. |
| 10 | **Knob-border misdiagnosis** | Believed the "border" was glass/vibrancy; tried `allowsVibrancy`; built a **two-window architecture**; a screenshot/pixel check finally showed it was the **keyboard focus ring**, fixed with one modifier; the two-window code (and its empty-canvas bug) was deleted. | **Most expensive detour** | **Agent, entirely.** An architecture built on an unverified hypothesis. |
| 11 | Port prototype → app | Swapped the AppKit popover body for the validated SwiftUI; rewired controllers. | Efficient | — |
| 12 | Visual micro-tuning | Output header (O6); padding; flank color `#384057` + dark-mode variant; unselected-glyph color (**two avoidable detours**: changed the *circle* when "glyph" was meant; tuned the *dark* branch while the user viewed *light*); notched MacBook icon; headphones icon + size. | Sink | **Shared.** Element/mode ambiguity (and partly the agent's job to *ask*); multi-monitor screenshot misses (agent's job to capture deterministically). |
| 13 | Right-click menu | Native visibility options → recognized as nonsensical for a single-entry agent → reduced to Launch at Login + Quit; fixed auto-persisted `isVisible`. | Efficient | — (good product call) |
| 14 | Publish | Public repo, MIT, releases. | Efficient | — |
| 15 | **Hardware volume keys + permission churn** | `CGEventTap`, HUD, BetterDisplay deferral, step grid. Then ~6 Accessibility re-grants because each ad-hoc reinstall wiped TCC. | **Large sink** | **Agent.** A *systemic signing problem*; re-granting was a symptom the agent kept treating per-incident, even abandoning the correct fix midway over a trivial `openssl` flag. |
| 16 | Scroll-to-adjust | Over the popover, then the menu-bar icon; HUD suppressed when popover open. | Efficient | — |
| 17 | Icon fill animation | Attempted; read as a snap / regressed; reverted. | Sink | **Agent** (chased a polish the status-item API can't deliver smoothly). |
| 18 | Adversarial review | 20-question review → fixed all legitimate findings (async DDC I/O was a real ship-blocker) → verified by a second pass. | **High value** | **Agent** should have run it at milestones, not once at the end. |
| 19 | Signing root-cause fix | Stable self-signed identity → cert-based, build-invariant designated requirement → grant persists; proven across reinstalls. | The right fix, late | **Agent** (≈10+ turns later than it should have landed). |

---

## 3. The big sinks, root-caused — and who owned them

### A. Window/material trial-and-error (phases 4–6) — **Agent**
macOS rendering rules (which container yields the material, why a slider renders
grey, why vibrancy needs a key window) were discovered empirically *inside the
production app*, one pivot per build. **This was not a guidance gap.** The user
had already supplied the target; the missing piece was expert knowledge and a
disciplined way to acquire it. The fix the agent eventually used — an isolated
prototype — existed the whole time and was the user's suggestion, not the
agent's reflex.

### B. The knob-border misdiagnosis (phase 10) — **Agent, entirely**
The instructive failure. A *plausible* cause (glass styling) was acted on without
*verifying* it; a two-window architecture was designed, built, and shipped, and
it spawned a derivative bug. A ten-minute screenshot/pixel comparison — done only
much later — revealed the real cause (focus ring), fixed in one line. No user
input could have prevented this; only the agent verifying before architecting.

### C. Pixel-tuning round-trips (phases 7, 12) — **mostly inherent, partly shared**
Iterative visual matching is intrinsically a loop, and the user provided the
references that made it possible. Two avoidable slices: (1) **ambiguity** — a
correction that didn't name the element or the appearance mode (shared, but the
agent should *ask* rather than guess and risk a wrong-variable change); (2)
**agent tooling** — multi-monitor screenshots that repeatedly missed the window,
which the agent should have handled deterministically (offscreen render / capture
all displays) from the first miss.

### D. Ad-hoc-signing permission churn (phases 15, 19) — **Agent**
Each reinstall reset the Accessibility grant because ad-hoc signatures carry a
`cdhash`-based designated requirement that changes every build. The permanent fix
(a stable self-signed identity → a cert-based, build-invariant requirement) is a
~30-minute job. Treating the recurring re-grant as a chore rather than a *bug in
the build process* — and abandoning the correct fix once over a fixable tooling
error — is the agent's failure, full stop.

---

## 4. What the user did well

- **Provided the reference (screenshots) early and throughout** — the visual
  target was never the bottleneck.
- **Proposed isolating the unknown in a prototype** — the single highest-leverage
  instruction in the project, and the thing that broke the material deadlock.
- **Gave precise, decisive feedback** ("not even close, for a forgery"; "keep the
  native pill") and made the subjective calls quickly when asked.
- **Made strong product judgments** — e.g. rejecting the nonsensical native
  right-click options in favor of something functional.
- **Supplied exact values when they actually knew them** (`#384057`, the 2/5/10
  step grid, the static-vs-variable glyph behavior), proactively.
- **Caught real regressions** the agent missed (the returning knob "border"; the
  HUD appearing over the popover; the menu-bar icon not tracking DDC changes).

This is, by any fair reading, good stewardship by a non-expert domain owner.

---

## 5. The narrow, honest set of user-side accelerators

These are *interaction-hygiene* items within the user's knowledge — explicitly
**not** "supply expert specs you don't have." Even fully applied, they address
the smaller sinks (C, parts of #12); they would **not** have prevented the big
ones (A, B, D), which were the agent's.

1. **Name the element and the state in a correction.** "Darker" cost two wrong
   attempts; "the *speaker glyph*, in *dark mode*" costs zero. (Equally, the agent
   should have *asked* instead of guessing.)
2. **State environment facts you already have, once.** Multi-monitor and your
   current appearance mode caused a few detours purely because they surfaced
   late; both were yours to know and cheap to mention.
3. **Batch related visual tweaks.** Each one-line change triggered a reinstall —
   which, until the signing fix, also reset the permission. Grouping tweaks would
   have collapsed several reinstall cycles. (The deeper fix was the agent's:
   don't reinstall — and don't break the grant — for popover-only changes.)
4. **Escalate recurring pain into a directive.** After the 2nd or 3rd re-grant,
   "stop re-granting — make this persist" would have surfaced the systemic fix
   sooner. *Caveat:* the agent should not have needed the prompt; a recurring
   manual step is the implementer's signal to fix the system.

Note how every item is hedged toward the agent. That is the correct balance: the
user's realistic contribution to speed is modest interaction hygiene; the
substantive acceleration was always the agent's to deliver.

---

## 6. What the agent must own (the bulk of the lost time)

1. **Possess or systematically acquire the domain knowledge.** The material/
   window/slider thrash was an expertise gap. When expertise is missing, the
   obligation is to *acquire it cheaply* — not to flail in the production app.
2. **Isolate before guessing.** Any "how does macOS actually render/behave here?"
   question warrants a throwaway prototype *before* production code. The agent did
   this only when prompted; it must be the default reflex.
3. **Verify root cause before architecting.** The two-window architecture is the
   cautionary tale: a cheap empirical check beats an expensive structure built on
   a hypothesis, every time.
4. **Fix systemic friction the first time it bites.** A manual step recurring ≥2×
   is a process bug to eliminate (here: signing), not a chore to repeat.
5. **Confirm the target before mutating it.** Ask "the glyph or the circle?"
   rather than risk a wrong-variable change.
6. **Make verification deterministic.** Offscreen rendering and capturing all
   displays should have replaced the flaky multi-monitor screenshots immediately.
7. **Run the adversarial review at milestones.** The main-thread-DDC ship-blocker
   survived many phases; periodic review would have caught it early.

---

## 7. The optimized playbook (same outcome, far fewer turns)

Restarting with what we now know — and with responsibility correctly placed:

1. **Spike:** prove DDC read/write end-to-end. *(done well)*
2. **Rendering lab first — agent-led:** an isolated prototype that establishes,
   before any production code, that **a single `NSGlassEffectView` key window +
   `focusEffectDisabled` native `Slider`** is the recipe (real material, clean
   knob, blue fill). *Removes sinks A, B, and most of 6.* The user supplies the
   reference (as they did); the agent supplies the method.
3. **Stable signing on day one — agent-led:** `setup-signing.sh` before the first
   install. *Removes sink D entirely (zero re-grants).*
4. **Build on the proven recipe;** wire CoreAudio/DDC; add keys/HUD/scroll. Tune
   visuals in **batched** passes against the user's reference, with element/mode
   named and deterministic capture. Run the **adversarial review at each
   milestone.**
5. **Publish.**

The destination is identical; the wandering — material churn, the two-window
detour, much of the pixel ping-pong, and all of the permission churn — was the
agent's to prevent, and largely does.

---

## 8. The transferable lessons

> **For the implementer (the agent): verify before you architect, isolate before
> you guess, and never offload your domain — or your recurring friction — onto
> the customer.** The two worst sinks (the knob-border architecture and the
> signing churn) shared one cause: acting on a plausible story instead of cheaply
> proving the real one. The third lesson is the meta-one this document had to
> correct in itself: when a project runs long, the implementer's first instinct
> may be to find what the customer could have done differently — but the honest
> audit usually points back across the table.

> **For the domain owner (the user): you supplied intent, reference, decisions,
> and environment facts — which is your job, and you did it well.** The realistic
> lever on your side is *interaction hygiene* (name the element/state, state what
> you already know, batch and escalate), not pre-supplying expertise you were
> never expected to hold.
