# Makinect Light-Show Engine — Research & Proposal Package

The index for the `docs/lightshow` series. Start here, then read in order: [01-video-analysis](01-video-analysis.md) · [02-domain-primer](02-domain-primer.md) · [03-landscape](03-landscape.md) · [04-proposals](04-proposals.md) · [05-critique](05-critique.md) · [06-roadmap](06-roadmap.md) · [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md).

---

## Executive summary

Makinect is a mature macOS Swift+Metal audio-reactive engine. The goal of this package is to chart its evolution into software that produces world-class, geometry-sharp audio-reactive **light shows** for **LED wall / projection** — reproducing the look and sound-fidelity of our reference, [INZO – "Overthinker" (Unofficial 4K Laser Show)](https://www.youtube.com/watch?v=UVaobBtZU2w) by Vox Daemon. We watched that video closely (80 exported frames plus the captions transcript), and its central lesson is counterintuitive: **the show's "sharpness" is not a rendering property, it is an editing decision.** The beams are crisp because galvos draw razor lines — but the show is *world-class* because it fires hard on the transient and then gets out of the way. The craft is **restraint** and a **three-timescale sync model**: a *structural* layer (palette + pattern family on section boundaries), a *rhythmic* layer (scan/beam-count pulse on the BPM grid), and a *transient* layer (sub-frame flashes on individual kicks/snares). An engine that reacts to everything smears all three into mush. Negative space — including blackout as a *composed beat* — is content, not absence.

The headline finding is that **Makinect already is the hard 80%.** It ships a production-grade DSP audio brain (`Makinect/Visualizations/AudioEngine.swift`: 8-band log FFT, spectral-flux **onset**, YIN pitch, chromagram chord, autocorrelation BPM, Krumhansl-Schmuckler key, BS.1770 LUFS — at ~1–2 frame latency) and **38 Metal visualizers**, several of them (`MandelbulbAviary` raymarching, `StableFluids`, the 65,536-particle `ParametricSwarm`) categorically *harder* than the geometric laser look we want. The crucial latency truth — ML beat-trackers run ~100–200 ms, far too slow for tight transient sync, while Makinect's DSP onset is sub-frame — is the architectural fact that shapes everything. What's genuinely missing is **output** (NDI/Syphon, multi-output, projection/output mapping), a **vector/geometry render layer** (a normalized-space "SceneGraph" of beams/lines/polygons with crisp additive + bloom), and **show-control** (timeline/cue, Ableton Link + SMPTE timecode, audio→output latency metering). Almost every gap is bounded engineering, not open research.

The recommendation is **Hybrid D = A + C**: build our own projection engine (A) *and* an AI choreographer (C) as one product. C is the brain — it scores a track **offline** into an editable cue timeline (color arcs, energy curve, negative-space map, pattern selection on the BPM grid); A is the hands — a deterministic <10 ms engine that performs the score while live spectral-flux onsets punch the hits. AI never sits in the live loop. Output is **LED/projection only** (no physical lasers — that is a one-line "someday, not now" footnote); the laser show is reproduced as a **geometric visual vocabulary** (beams, fans, tunnels, bursts, polygons) plus color choreography and disciplined negative space. The strategic stance is to **build something new** on our unfair advantage — body-tracking (Kinect/Vision) + AI-scored, geometry-sharp sound-to-light — and explicitly **not fight Resolume head-on**. TouchDesigner (B) is demoted to a documented interop/escape-hatch.

---

## Resolved decisions

> These are settled. The docs below execute them; they do not relitigate them.

1. **End goal — both.** A sellable product *and* tooling for the user's own shows.
2. **Output target — LED wall / projection only (screen/raster).** No physical lasers, now or as a roadmap phase. The "laser show" is an **aesthetic** reproduced as a geometric visual vocabulary + color choreography + disciplined negative space. DMX fixtures are secondary/optional interop only; physical galvo lasers / ILDA are a one-line "someday, not now" footnote.
3. **This PR is docs-only.** No engine code. Engine work is a follow-up PR sequenced in [06-roadmap](06-roadmap.md).
4. **Chosen direction — Hybrid D = A + C** (build-our-own projection engine + AI choreographer), foregrounded. TouchDesigner (B) is demoted to interop/escape-hatch. Strategic stance: build something new / unfair advantage — explicitly **not** competing with Resolume head-on.

---

## Reading order

1. **[01-video-analysis](01-video-analysis.md) — the thesis.** A frame-by-frame, timestamped walkthrough of the INZO "Overthinker" reference (real RGB galvo lasers, ~150 BPM half-time feel, choreographed to Alan Watts spoken word). Establishes the load-bearing **three-timescale sync model** (structural / rhythmic / transient), argues that perceived sharpness is *tight transients + disciplined negative space*, and distills 12 concrete design principles we steal — including "expose three reactivity channels, not one knob" and "blackout is a first-class cue."

2. **[02-domain-primer](02-domain-primer.md) — shared vocabulary.** The physics and perceptual grounding: the geometric primitive alphabet (beam, fan, matrix/tunnel, starburst, spokes, polygon, Lissajous), why **additive blending + bloom + HDR tonemap** makes geometry read as *emitted light*, LED-vs-projection trade-offs (true black is the deciding factor), what each audio feature should drive (BPM vs onset vs beat; spectral bands; song structure), color theory for light, and the core thesis on **negative space**.

3. **[03-landscape](03-landscape.md) — the competition.** An honest, cited map of the eight incumbents (Resolume, TouchDesigner, Notch, MadMapper, disguise, vvvv, Max/MSP+Jitter, VDMX) with a comparison table and deep reads on the four that matter. Where Makinect fits, the bounded-engineering gap list (output / vector layer / mapping / show-control / clock sync), the Windows-centricity reality, and the latency truth that picks the architecture.

4. **[04-proposals](04-proposals.md) — the four directions.** A (build our own engine, ~80% reuse), B (TouchDesigner interop, demoted), C (AI choreographer + DSP performer split), and **D = A + C (chosen)**. Text architecture diagrams, the **SceneGraph** and **choreography-score** concept sketches, per-proposal latency budgets, build timelines, and a decision matrix that lands on D (score 26). Establishes that AI is quarantined offline and D's live latency equals A's (~20–40 ms via Syphon).

5. **[05-critique](05-critique.md) — the challenge.** Assumes the plan is good and attacks it anyway: "festival-grade" is a claim we can't yet back; the pro market pre-programs to timecode (reframe the pitch from "live-reactive" to "AI-fast, timecode-ready authoring"); be ruthless about *where* AI lives; a screen approximates but never replicates a galvo; macOS/Metal is the biggest strategic fork (own the **score** as the cross-platform layer); commercial licensing landmines; and why disrupting Resolume head-on fails. Ends with five cheap, days-not-quarters experiments to run before the roadmap hardens.

6. **[06-roadmap](06-roadmap.md) — the build plan.** Turns D into phased engine PRs: **Phase 0** (these docs) → **Phase 1** (the `LaserCanvas` SceneGraph + geometric visualizer — the make-or-break de-risk) → **Phase 2** (NDI/Syphon output + mapping) → **Phase 3** (timeline/cue + Link/SMPTE + low-latency control thread + latency metering) → **Phase 4** (offline AI choreographer + score editor + deterministic performer). Per-phase files-touched tables, acceptance criteria, build/buy gates, milestones, and a "definition of done" for a v1 self-run show.

7. **[07-visual-and-tech-catalog](07-visual-and-tech-catalog.md) — the approvable building blocks.** The doc to sign off on: (a) the visual module catalog mapping each look to its audio driver and the existing Makinect visualizer that proves the capability; (b) the shader-technique catalog (7 of 10 already present in `Shaders.metal`, one genuinely net-new: instanced-line geometry); (c) the open-source dependency table with commercial-ship verdicts (ISF/Syphon/OSCKit/Apple = ship-safe; Link/NDI/LYGIA = budget or re-implement; Shadertoy = reference only); and (d) the honest "can we build this?" confidence + risk register.

---

## What this PR is / isn't

- **It is** a docs-only research and proposal package: the seven documents above, plus reference frames. No `.swift`, no `.metal`, no project-file edits.
- **It isn't** engine code. Implementation ships in follow-up PRs sequenced by [06-roadmap](06-roadmap.md), beginning with Phase 1 (the `LaserCanvas` SceneGraph + geometric visualizer).

---

## Status & next step

**Status:** Phase 0 complete (this series). **Next step:** awaiting approval of the [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md) building blocks → then the Phase 1 engine PR (vector/geometry render layer) per [06-roadmap](06-roadmap.md).
