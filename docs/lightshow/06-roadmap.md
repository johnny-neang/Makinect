# Roadmap — Phased Build Plan for the Engine PRs

Part of the docs/lightshow series — see [00-README](00-README.md). Related: [04-proposals](04-proposals.md) (the four directions and why Hybrid A+C won) and [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md) (the visual vocabulary and shader catalog this roadmap builds toward).

---

This document is the bridge between strategy and commits. The strategy is decided (Hybrid = A + C: build our own projection engine, add an AI choreographer, keep TouchDesigner as an escape hatch, and treat physical lasers/DMX as a deferred footnote — see [04-proposals](04-proposals.md)). This roadmap turns that into a phased, buildable plan for the **follow-up engine PRs**. This PR is docs-only; no engine code ships here.

The sequencing is deliberate and load-bearing: **prove the look on-screen before spending a dollar on output plumbing, show-control, or AI.** Phase 1 is the whole bet de-risked on a laptop with no new hardware. Everything after it is leverage on a thing we already know looks right.

## TL;DR phase map

| Phase | Theme | Ships | Effort | Hardware needed | Biggest risk it retires |
|---|---|---|---|---|---|
| **0** | Docs package | This series | done | none | "Do we even agree on the bet?" |
| **1** | Vector/geometry render layer | `LaserCanvas` SceneGraph + geometric visualizer | ~3–5 wk | none | "Can we actually make the *look*?" |
| **2** | Output | NDI + Syphon out, multi-canvas, output/projection mapping | ~3–4 wk | a projector / LED wall to test | "Can it leave the laptop and hit a wall?" |
| **3** | Show-control | Timeline/cue, Ableton Link + SMPTE, low-latency control thread, latency metering | ~4–6 wk | audio interface; optional Ableton | "Is the sync tight enough to feel pro?" |
| **4** | AI choreographer | Offline analysis → editable score → deterministic performer + score editor UI | ~6–10 wk | none (offline compute) | "Is the AI angle real or a demo?" |

Effort assumes one focused engineer. Phases 1→3 are strictly sequential for value delivery but 2 and 3 can overlap once 1 lands. Phase 4 depends only on Phase 1's SceneGraph and Phase 3's clock, so it can begin in parallel with Phase 2.

---

## Phase 0 — The docs package (this PR) ✅

**Goal.** Get strategy, landscape, licensing, and visual vocabulary onto paper so the engine PRs are executing a decided plan, not relitigating it.

**Deliverables.** The `docs/lightshow/` series: README, the watch/analysis of the reference video, landscape + licensing facts, the four proposals with the Hybrid decision, the visual-and-tech catalog, and this roadmap.

**Acceptance criteria.** A sharp engineer can read the series and start Phase 1 without asking "but why are we building our own engine instead of using TouchDesigner?" or "is this shader safe to ship?"

**Out of scope here.** Any source change. No `.swift`, no `.metal`, no project-file edits.

---

## Phase 1 — Vector/geometry render layer (the de-risk phase)

This is the phase that matters. If we nail the laser *look* on-screen, the rest is engineering we know how to do. If we can't, we should know now — before output plumbing or AI.

### Goal

Add a **vector/geometry render layer** — a "SceneGraph" of beams, fans, tunnels, starbursts, and polygons in normalized space — and a new geometric visualizer that draws it with crisp **additive blending + bloom** to reproduce the [reference video's](01-video-analysis.md) galvo-laser aesthetic. Drive it entirely from the existing `AudioEngine` feature stream. No new hardware, no network, no AI. Just: *does it look like the INZO show on a monitor?*

The grounding already proves we can: the engine ships `MandelbulbAviary` (raymarched fractal), `StableFluids`, and `ParametricSwarm` (65,536 GPU particles). A scene of additive line primitives is **lower** GPU complexity than what's already running. The risk here is *aesthetic and architectural*, not "can the GPU do it."

### Deliverables

1. **`LaserCanvas` SceneGraph** — a CPU-side scene description in normalized device coordinates (`-1…1`), independent of output resolution. Primitive types: `beam` (line segment with width + falloff), `fan` (radial bundle of beams from an apex), `tunnel` (concentric/receding rings), `starburst` (symmetric radial spokes), `polygon` (closed N-gon outline). Each primitive carries color (HSV), intensity, and a `groupID` for choreography. This is the layer the AI scorer (Phase 4) and any future output (the [deferred output seam](#out-of-scope-deferred-on-purpose)) will target.
2. **A geometric visualizer module** that consumes the SceneGraph, packs primitives into GPU buffers, and renders them with additive blend + a bloom pass tuned for the razor-edge-plus-glow laser feel.
3. **Audio-reactive bindings** mapping `AudioEngine` features to SceneGraph parameters across the three sync timescales the [reference analysis](01-video-analysis.md) identified: structural (palette/pattern family), rhythmic (scan motion + beam-count on the BPM grid), and transient (sharp cuts/flashes on onsets). Crucially, the binding must encode **restraint** — fire hard on the transient, then get out of the way — not react to everything.
4. **A `*Config.swift` binding** exposing the knobs (palette, density ceiling, negative-space bias, bloom intensity, additive gain) so it's tweakable live like every other visualizer.

### Files created / touched

Mirror the existing per-visualizer pattern exactly — this is well-trodden ground in the codebase:

| File | Action | Why |
|---|---|---|
| `Makinect/Visualizations/LaserCanvas.swift` *(new)* | create | The SceneGraph data model (primitives, groups, normalized space). The reusable seam. |
| `Makinect/Visualizations/LaserGeometryVisualizer.swift` *(new)* | create | Conforms to the `Visualizer` protocol in `Makinect/Visualizations/Visualizer.swift`; builds GPU buffers from the SceneGraph; drives the additive + bloom pass. |
| `Makinect/Visualizations/LaserGeometryConfig.swift` *(new)* | create | `@Observable` config mirroring e.g. `ParametricSwarmConfig.swift`. |
| `Makinect/Visualizations/Shaders.metal` | edit | Add the beam/line additive vertex+fragment shaders and a bloom/threshold pass. Reuse existing helpers: `hsv2rgb`, `passthrough_vs`, the ACES tonemap. |
| `Makinect/Visualizations/Visualizer.swift` | edit | Add a `VisualizationKind` case (currently 38 cases) for the geometric laser viz; extend `VisualizerInputs` only if a new audio field is genuinely needed (prefer reusing existing). |
| `Makinect/Visualizations/MetalKinectView.swift` | edit | Factory wiring for the new kind; ensure the two-pass pipeline (visualizer → offscreen → `common_post_fs`) carries the bloom correctly. |
| `Makinect/Visualizations/VisualizationCommonParams.swift` | edit (maybe) | The 6 universal knobs (`audioReactivity`, `speedMul`, `hueShift`, `saturationMul`, `brightnessMul`, `glowMul`) likely already cover most needs; `glowMul` maps naturally to bloom. Touch only if a knob is missing. |

### Acceptance criteria

- A new `VisualizationKind` renders a SceneGraph of beams/fans/tunnels/starbursts/polygons at 60 Hz with no frame drops on the dev machine.
- Side-by-side with [reference frames](frames/), a neutral observer agrees it reads as "a laser show" — razor lines, additive glow, disciplined negative space — not "a generic music visualizer."
- The three sync timescales are demonstrably distinct: palette changes on section boundaries, scan/count pulses on the BPM grid (from `AudioEngine`'s autocorrelation BPM), and flashes snap on spectral-flux onsets within ~1–2 frames (the latency the audio brain already delivers).
- The config exposes a **negative-space bias** that, turned up, produces the intro's single-violet-fan restraint — proving we built *restraint*, not just density.

### Rough effort

~3–5 weeks. The SceneGraph model and additive/bloom shaders are the bulk; the per-viz scaffolding is a known quantity because the codebase has done it 38 times.

### Dependencies

None external. Depends only on the existing `AudioEngine.swift` feature stream and the existing render framework. This is why it's first — nothing blocks it.

### Build / Buy gate

| Concern | Decision | Rationale |
|---|---|---|
| Shader techniques (SDF lines, glow falloff) | **Learn, write our own** | [Inigo Quilez 2D distance functions](https://iquilezles.org/articles/distfunctions2d/) are technique reference (knowledge, not a code license). We write the Metal. |
| Pre-built shader pack | **Lean on ISF where it helps** | [ISF + ISF-for-Metal](https://docs.vidvox.net/opensource/) is free for commercial use with a Metal renderer — usable for prototyping post-FX without licensing risk. Our core geometric shaders we still write. |
| LYGIA / Shadertoy code | **Reference only, do not ship** | [LYGIA](https://github.com/patriciogonzalezvivo/lygia) is Prosperity-licensed (paid for commercial); [Shadertoy](https://www.shadertoy.com/terms) defaults to CC BY-NC-SA. Fine to learn from, not to paste. |
| Bloom / upscale | **Buy (Apple SDK) — MetalFX** | MetalFX gives high-quality bloom/upscale inside the Apple SDK at no license cost. No reason to hand-roll. |

**Verdict: build the SceneGraph and core geometric shaders ourselves** (this is the IP and the unfair advantage); **buy/lean on Apple + ISF for the commodity post-FX.**

---

## Phase 2 — Output

Now that it looks right on a monitor, get it off the laptop and onto a wall.

### Goal

Send the rendered output to real surfaces: **NDI** (network, cross-platform) and **Syphon** (macOS inter-app) video out, support **multiple output canvases**, and add **output/projection mapping** (warp/keystone to fit a physical surface).

### Deliverables

1. **Syphon output** — publish the final render texture as a Syphon server so MadMapper/Resolume/any Syphon client can grab it on the same Mac.
2. **NDI output** — publish over the network for cross-machine/LED-processor workflows.
3. **Multi-output / multi-canvas** — render the same SceneGraph to N independently-mapped outputs (e.g., a main wall + a side panel).
4. **Output/projection mapping** — per-output warp + mask so the normalized SceneGraph lands correctly on an angled surface.
5. **Output configuration UI** — pick outputs, assign canvases, save/load via the existing persistence layer.

### Files created / touched

| File | Action | Why |
|---|---|---|
| `Makinect/Visualizations/OutputManager.swift` *(new)* | create | Owns output targets (Syphon/NDI/window), the canvas list, and per-output mapping. |
| `Makinect/Visualizations/SyphonOutput.swift` *(new)* | create | Wraps the Syphon server, publishing the post-FX texture. |
| `Makinect/Visualizations/NDIOutput.swift` *(new)* | create | Wraps the NDI sender. |
| `Makinect/Visualizations/MetalKinectView.swift` | edit | Tee the final post-FX texture to `OutputManager` after `common_post_fs`. |
| `Makinect/MKAppState.swift` | edit | Surface output state/selection alongside existing tabs/scene-arming. |
| `Makinect/MKPersistence.swift` | edit | Persist output config + mapping in the existing Codable-JSON-in-UserDefaults scheme. |
| New output/mapping UI screen *(new, alongside e.g. `MKMidiOutputScreens.swift`)* | create | Follow the existing screen pattern. |

### Acceptance criteria

- The Phase-1 visual appears live in a third-party Syphon client (e.g., MadMapper) on the same Mac, and in an NDI monitor on a second machine.
- Two output canvases can be driven from one SceneGraph with independent mapping, and the mapping survives a save/load.
- A keystoned projection lands square on a test surface using the warp UI.

### Rough effort

~3–4 weeks. Syphon is straightforward; NDI's SDK and mapping math add the bulk.

### Dependencies

Phase 1 (there must be something worth outputting). A projector or LED wall to validate mapping in the real world.

### Build / Buy gate

| Concern | Decision | Rationale |
|---|---|---|
| Syphon | **Buy/integrate — ship-safe** | [Syphon-Framework](https://github.com/Syphon/Syphon-Framework) is Simplified BSD, commercial OK. Integrate, don't reinvent. |
| NDI | **Buy/integrate — mind the terms** | NDI SDK is free but proprietary (branding/redistribution rules). Integrate carefully; honor branding requirements in a product. |
| Projection/output mapping | **Build the minimum; interop for the hard cases** | Warp/keystone/mask for our own shows is buildable. Full pixel-mapping is owned by MadMapper/Resolume/disguise — we deliberately **do not** compete head-on (per [04-proposals](04-proposals.md)). Syphon/NDI out *is* the interop path to those tools when a show needs heavy mapping. |

**Verdict: integrate the commodity transports (Syphon/NDI), build only the mapping we need for our own shows, and let Syphon/NDI be the escape hatch to industry mappers.**

---

## Phase 3 — Show-control

Looks right, reaches the wall. Now make the **sync** feel pro — the thing the [reference analysis](01-video-analysis.md) says is the real source of perceived "sharpness."

### Goal

Add a **timeline/cue system**, **Ableton Link + SMPTE timecode** sync, a **dedicated low-latency audio→control thread** decoupled from the 60 Hz render, and **audio→output latency metering** so we can prove and tune the tightness.

### Deliverables

1. **Timeline / cue system** — an editable list of cues on a musical/time grid that arm SceneGraph states (palette, pattern family, density, negative-space). Builds on the scene-arming + scene-bar + tap-tempo already in `MKAppState.swift`.
2. **Ableton Link sync** — phase/tempo sync to a Link session for sample-accurate musical timing.
3. **SMPTE timecode** — chase external timecode for fixed-show playback.
4. **Dedicated control thread** — move audio→control off the render thread so onset→flash latency is bounded by DSP, not by the 60 Hz frame cadence. The audio brain already computes on the render thread and publishes smoothed to main (~1–2 frames); this phase formalizes a separate low-latency path so the **transient layer stays tight** even when the render hitches.
5. **Latency metering** — a measured, on-screen audio→output latency readout to tune and prove the sync.

### Files created / touched

| File | Action | Why |
|---|---|---|
| `Makinect/ShowControl/Timeline.swift` *(new)* | create | Cue model + transport (play/pause/locate), on the BPM/time grid. |
| `Makinect/ShowControl/LinkSync.swift` *(new)* | create | Ableton Link wrapper (tempo/phase). |
| `Makinect/ShowControl/TimecodeSync.swift` *(new)* | create | SMPTE chase. |
| `Makinect/ShowControl/ControlThread.swift` *(new)* | create | Low-latency audio→control loop, decoupled from render. |
| `Makinect/Visualizations/AudioEngine.swift` | edit | Expose a low-latency tap (onset/transient) to the control thread without disturbing the existing smoothed main-thread publish. |
| `Makinect/MKAppState.swift` | edit | Own transport/cue state alongside tap-tempo + scene-bar. |
| `Makinect/MKPersistence.swift` | edit | Persist timelines/cues (named, like snapshots today). |
| Latency-meter UI *(new screen)* | create | On-screen readout, following the existing screen pattern. |

### Acceptance criteria

- A cue list plays back and arms SceneGraph states on the grid; cues are editable and persist.
- The engine locks to an Ableton Link session: changing tempo in Ableton moves the rhythmic layer in sync.
- It chases SMPTE timecode for a deterministic fixed show.
- Measured audio→output latency is displayed and is low enough that transient flashes feel "on the hit" — targeting the sub-frame DSP path, **well under** the ~100–200 ms of [ML online beat-trackers](https://transactions.ismir.net/articles/10.5334/tismir.189), which we explicitly do **not** put in the live loop.

### Rough effort

~4–6 weeks. The cue system and control-thread decoupling are the substance; Link/SMPTE integration is bounded.

### Dependencies

Phase 1 (states to arm). Benefits from Phase 2 (real output to measure latency against). An audio interface for honest latency numbers; Ableton for Link testing.

### Build / Buy gate

| Concern | Decision | Rationale |
|---|---|---|
| Beat/onset detection | **Build — already have it** | `AudioEngine.swift` already ships spectral-flux onset + autocorrelation BPM via vDSP/Accelerate. This is the sub-frame path. No ML in the live loop (too slow — see acceptance criteria). |
| Real-time beat-tracker reference | **Reference if ever needed** | [BTrack](https://github.com/adamstark/BTrack) is real-time C++ if we ever want a second opinion; not required given our DSP. |
| Ableton Link | **Buy/license for product** | [Link](https://github.com/Ableton/link) is dual GPLv2+/proprietary — a closed product must license from Ableton. Prototype under GPL terms; license before commercial ship. |
| SMPTE timecode | **Build** | LTC/MTC chase is bounded DSP/MIDI work; no licensing concern. |
| OSC (if we add remote control) | **Buy/integrate — ship-safe** | [OSCKit](https://github.com/orchetect/OSCKit) is MIT. |

**Verdict: build on our existing DSP for the tight path; license Ableton Link before commercial release; everything else is in-house or MIT.**

---

## Phase 4 — AI choreographer

The defensible, genuinely-novel part. Critically: **AI is not in the live render loop** (the latency truth forbids it — see [04-proposals](04-proposals.md) and the Phase 3 acceptance criteria). AI works offline and emits an editable score; a deterministic engine performs it.

### Goal

Offline (or near-real-time) track analysis → an **editable choreography score**; a **deterministic live performer** that runs the score with onset-driven **micro-reactivity** on top; and a **score editor UI**.

### Deliverables

1. **Offline track analyzer** — ingest a track (and, where available, stems / structure / lyrics) and produce: section boundaries, an energy curve, a negative-space map, color arcs, and geometric pattern/shape selections on the BPM grid. This directly encodes the three-timescale sync model from the [reference analysis](01-video-analysis.md).
2. **Choreography score format** — a serializable, **human-editable** cue timeline (the AI proposes; the human owns the final edit). Reuses the Phase 3 cue model.
3. **Deterministic performer** — a <10 ms DSP/GPU path that runs the score against the SceneGraph, with live spectral-flux onsets layered on for micro-reactivity. No AI inference in this loop.
4. **Score editor UI** — review/tweak/approve the AI's choreography: adjust color arcs, nudge cues, sculpt negative space.

### Files created / touched

| File | Action | Why |
|---|---|---|
| `Makinect/AI/TrackAnalyzer.swift` *(new)* | create | Offline analysis → score (sections, energy, negative space, color/shape choices). |
| `Makinect/AI/ChoreographyScore.swift` *(new)* | create | Codable score format; extends the Phase 3 cue model. |
| `Makinect/AI/ScorePerformer.swift` *(new)* | create | Deterministic runtime: feeds `LaserCanvas` from the score + live onsets. |
| `Makinect/ShowControl/Timeline.swift` | edit | Load/run a `ChoreographyScore` through the existing transport. |
| `Makinect/Visualizations/LaserCanvas.swift` | edit (maybe) | Extend primitives only if the AI vocabulary needs shapes Phase 1 didn't cover. |
| Score editor UI *(new screen)* | create | Review/edit/approve, following the existing screen pattern. |
| `Makinect/MKPersistence.swift` | edit | Persist scores alongside snapshots/timelines. |

### Acceptance criteria

- Feeding a track produces a score whose section boundaries and energy curve a human agrees with on first listen.
- The performer runs the score deterministically at <10 ms control latency, with onset micro-reactivity layered on, never invoking AI in the live loop.
- A human can open the score in the editor, change a color arc or carve negative space, and the change is honored on the next run.
- End-to-end: a never-before-seen track → AI score → human polish → live performance that holds the three-timescale discipline of the reference show.

### Rough effort

~6–10 weeks. The analyzer + score format + editor are each substantial; the performer is small because it leans on Phases 1 and 3.

### Dependencies

Phase 1 (SceneGraph to target) and Phase 3 (cue model + clock to run the score). Independent of Phase 2, so it can run in parallel with output work.

### Build / Buy gate

| Concern | Decision | Rationale |
|---|---|---|
| Offline analysis models | **Buy/use freely offline — latency irrelevant** | Offline, we can use heavier models (structure, stems, lyrics) that would be unusable live. This is the *correct* use of AI given the [latency truth](https://biff.ai/a-rundown-of-open-source-beat-detection-models/). |
| Live AI in the loop | **Do not build — architecturally banned** | Generative/diffusion AI is not viable at <20 ms. The score/performer split exists precisely to keep AI out of the hot path. |
| Live DSP onsets | **Build — reuse `AudioEngine.swift`** | Already ours, already sub-frame. |
| Score format | **Build — this is the IP** | The editable choreography score is the defensible artifact. It's ours. |

**Verdict: use heavy AI freely *offline*; ship a deterministic performer with zero AI in the live loop; own the score format outright.**

---

## Milestones

- **M0 — Docs merged.** This series lands. Strategy is canon. *(Phase 0)*
- **M1 — "It looks like a laser show."** The geometric visualizer renders the SceneGraph with additive + bloom, audio-reactive across all three timescales, and reads as a laser show next to the reference frames. *(Phase 1)* — **the make-or-break milestone.**
- **M2 — "It's on the wall."** Output via Syphon + NDI, multi-canvas, mapped onto a real projection/LED surface. *(Phase 2)*
- **M3 — "It's locked to the music."** Cue timeline + Ableton Link + SMPTE, low-latency control thread, measured/tuned latency. *(Phase 3)*
- **M4 — "The AI scored it, we polished it, it performed."** End-to-end AI score → human edit → deterministic live run. *(Phase 4)*

## Definition of done for v1 (our own show)

v1 is **the user running their own festival-grade show end-to-end** — not a SKU, not a marketplace listing. Concretely, v1 is done when:

1. A real track is analyzed (Phase 4) into an editable score, the user polishes it, and the score performs deterministically with tight onset micro-reactivity (Phases 3 + 4).
2. The geometric SceneGraph renders the full laser visual vocabulary — beams, fans, tunnels, starbursts, polygons — with crisp additive + bloom and **disciplined negative space**, holding the three-timescale sync of the reference show (Phase 1).
3. Output reaches a real LED wall / projection surface via NDI or Syphon, correctly mapped, with measured audio→output latency low enough to feel "on the hit" (Phases 2 + 3).
4. The whole thing runs a complete track — including the [reference show's](01-video-analysis.md) hardest beats: the intro's single-fan restraint, the iris-close → blackout as a compositional beat, and the rotating radial sunburst — without manual babysitting.

If the user can stand in front of a wall, hit play, and get the INZO-grade result *aesthetically* (we are reproducing the look as a [geometric visual vocabulary](07-visual-and-tech-catalog.md), not driving physical lasers), v1 is done.

## Out of scope (deferred on purpose)

- **Physical lasers (galvo/ILDA).** Not now, not as a roadmap phase. The laser show is an **aesthetic** reproduced on LED/projection, never real beams. (Someday-not-now footnote: an ILDA path via something like the [Helios DAC](https://github.com/Grix/helios_dac) is *conceivable*, but it brings [FDA/CDRH variance and audience-scanning safety law](https://www.fda.gov/radiation-emitting-products/home-business-and-entertainment-products/laser-light-shows) we are explicitly not signing up for.)
- **DMX / Art-Net / sACN fixture control.** Deferred to secondary/optional interop only. We are a screen/raster engine first. ([OLA](https://www.openlighting.org/ola/) exists if we ever want it.)
- **Head-to-head competition with Resolume/MadMapper/disguise on pixel-mapping.** Deliberately avoided (see [04-proposals](04-proposals.md)); we interop via Syphon/NDI instead.

**The clean output seam.** The Phase 1 `LaserCanvas` SceneGraph is defined in **normalized space, independent of any output device**. That is the whole point of putting it first: every future output target — Syphon, NDI, projection mapping, and *hypothetically* a DMX or ILDA emitter someday — is just another consumer of the same scene description. We are not painting ourselves into a screen-only corner; we are leaving a clean seam and choosing, for now, not to walk through it.

---

## Sources

- INZO – "Overthinker" (Unofficial 4K Laser Show), Vox Daemon — https://www.youtube.com/watch?v=UVaobBtZU2w
- Inigo Quilez, 2D distance functions (technique reference) — https://iquilezles.org/articles/distfunctions2d/
- ISF (Interactive Shader Format) open-source docs — https://docs.vidvox.net/opensource/
- ISF for Metal — https://vdmx.vidvox.net/blog/isf-for-metal
- LYGIA shader library (Prosperity License) — https://github.com/patriciogonzalezvivo/lygia
- Shadertoy terms (CC BY-NC-SA default) — https://www.shadertoy.com/terms
- Syphon Framework (Simplified BSD) — https://github.com/Syphon/Syphon-Framework
- Ableton Link (dual GPLv2+/proprietary) — https://github.com/Ableton/link
- OSCKit (MIT) — https://github.com/orchetect/OSCKit
- BTrack real-time beat tracker — https://github.com/adamstark/BTrack
- Online beat-tracking latency (ISMIR / TISMIR) — https://transactions.ismir.net/articles/10.5334/tismir.189
- Rundown of open-source beat-detection models — https://biff.ai/a-rundown-of-open-source-beat-detection-models/
- Open Lighting Architecture (OLA) — https://www.openlighting.org/ola/
- Helios DAC (open-source USB→ILDA) — https://github.com/Grix/helios_dac
- FDA/CDRH laser light show safety — https://www.fda.gov/radiation-emitting-products/home-business-and-entertainment-products/laser-light-shows
- Audience scanning (safety) — https://en.wikipedia.org/wiki/Audience_scanning
