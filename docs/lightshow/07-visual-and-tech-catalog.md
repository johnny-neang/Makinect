# Visual & Tech Catalog — The Approvable Building Blocks

Part of the docs/lightshow series — see [00-README](00-README.md). This is the doc you sign off on. It enumerates the exact visual modules, shader techniques, and third-party libraries we would build the festival-grade laser-aesthetic engine from — and then makes the honest case for whether we can actually build it. Read it alongside [01-video-analysis](01-video-analysis.md) (what the INZO "Overthinker" reference *is* and the three-timescale sync model that makes it sharp), [04-proposals](04-proposals.md) (the four directions and why we chose Hybrid A+C), and [06-roadmap](06-roadmap.md) (the build sequence and milestones).

The thesis of this document is blunt: **the visuals are the low-risk part.** Makinect already ships 38 audio-reactive Metal visualizers, several of which are materially harder than anything in the reference video. The geometric laser look is a *subtraction* from what we already do, not an addition. The risk lives almost entirely in show-control, the AI choreographer, and the discipline of negative space — not in pixels. This catalog is structured to make that asymmetry legible so the approval conversation is about the right things.

A note on how to read the "proven by" claims: when this doc says a look is "proven," it means the *rendering capability* (the GPU technique, the particle budget, the audio binding) already exists in a shipping Makinect visualizer. It does **not** mean the visualizer already looks like a laser show. Re-skinning an existing visualizer into the disciplined beam-and-blackout vocabulary of [01-video-analysis](01-video-analysis.md) is real work — it is just *low-uncertainty* work, because nothing about it is technically unproven.

---

## (a) Visual Module Catalog

Each row is a module we would expose as a composable layer in the new SceneGraph (normalized-space geometry on top of the existing raster shaders — see [04-proposals](04-proposals.md), Proposal A). "Audio feature that drives it" maps to the actual outputs of `Makinect/Visualizations/AudioEngine.swift` (8-band log FFT, spectral-flux onset, YIN pitch, chromagram chord, autocorrelation BPM, Krumhansl-Schmuckler key, BS.1770 LUFS). "Proven in Makinect by" cites an existing visualizer whose rendering capability covers the look. "New work needed" is the honest delta.

| Module | What it looks like | Audio feature that drives it | Already proven in Makinect by | New work needed |
|---|---|---|---|---|
| **Beam fans / radial spokes** | Evenly-spaced lines fanning from a point or edge; the intro's single violet fan and the 3:17 rotating sunburst. Geometry over chaos. | Onset for spoke-add transients; BPM grid for rotation phase; band energy for fan width; key/chord for hue. | `KineticWireframe` (line primitives, parametric sweeps), `SandMandala` (radial symmetry) | New: crisp instanced-line SceneGraph primitive in normalized space; per-spoke additive falloff. Medium-low. |
| **Tunnels / crossing beam matrices** | Receding grids of beams; symmetric tunnels that pulse on the grid (0:30–0:55 full beam-matrix). | BPM grid for scan/recede speed; band energy for beam count; onset for matrix "snap." | `HyperbolicTunnel` (full perspective-tunnel raymarch already shipping) | Re-skin tunnel into hard beams vs. surfaces; couple beam-count to a quantized BPM lattice. Low. |
| **Starbursts** | Symmetric explosive radial bursts on section markers and drops (0:30 purple, 1:14 green+blue, 2:40 dense climax). | Onset/transient for the burst trigger; LUFS for amplitude; chord for the multicolor spread. | `ParticleStorm`, `ParametricSwarm` (up to 65,536 GPU particles), `SandMandala` (symmetry) | New: radial burst emitter constrained to symmetric spokes (not omnidirectional spray). Low. |
| **Geometric primitives (squares / triangles / polygons)** | Hard-edged outlined shapes — the disciplined "shape vocabulary" of the laser look. | Onset for shape cuts; pitch/chord for which polygon; BPM for rotation. | `KineticWireframe` (line/edge rendering); SDF helpers in `Shaders.metal` | New: 2D SDF polygon library + stroked-edge (not filled) rendering for the beam look. Low. |
| **Kaleidoscope / mandala** | Mirrored, rotating symmetric fields; mesmeric breakdown texture. | Chromagram chord for palette; BPM for rotation; band energy for complexity. | `SandMandala`, `StainedCathedral` (both ship polar symmetry today) | Minimal — these are the closest existing visualizers to the target aesthetic. Tune palette + negative space. Very low. |
| **Scanning grids / Lissajous / wireframe** | Oscilloscope-style scanning curves and grids — the "galvo drawing a path" signature. | Pitch (Hz) → Lissajous frequency ratios; BPM → scan rate; onset → path retrigger. | `KineticWireframe` (parametric curve/grid rendering already present) | New: Lissajous parametric generator bound to pitch ratios; persistence/trail to mimic POV. Medium. |
| **Tunnels (perspective)** | Deep receding corridors; immersive wide-shot moments. | BPM for travel speed; LUFS for FOV pulse; onset for direction snaps. | `HyperbolicTunnel` (raymarched, shipping) | Mostly tuning + palette discipline. Very low. |
| **Particle storms / swarms** | Dense reactive point fields for high-energy drops; the "everything moving" climax texture. | Band energy for emission; onset for impulse; BPM for choreographed motion. | `ParticleStorm`, `ParametricSwarm` (65,536 GPU particles) | None on capability. Work is *restraint* — constraining the swarm to read as beams/geometry, not noise. Low. |
| **Plasma / fluid backdrops** | Soft volumetric color washes behind the hard geometry; used sparingly for contrast. | LUFS / low-band energy for slow swells; key for base palette. | `PlasmaSea`, `StableFluids`, `VolumetricAurora`, `SmokeGod` | None on capability — these *exceed* the reference's needs. Work is dialing them *down*. Trivial. |
| **Strobe / flash / blackout — the negative-space engine** | Hard transient flashes on kicks; the 2:54 iris-close to a single point; full blackout as a compositional beat (4:24 final hit). | Spectral-flux onset (sub-frame) for flashes; section boundaries + cue timeline for blackouts; LUFS gate for "get out of the way." | New module, but the *output path* exists: `common_post_fs` post-FX pass, `MKAppState.swift` panic/scene infra | New but **trivial** technically (alpha/exposure ramp + master gate). The hard part is *authoring* it well — see [01-video-analysis](01-video-analysis.md): "fire hard on the hit, then get out of the way." Restraint is the craft, not the code. |

The pattern across this table: there is **no row where the technical capability is unproven**, and several rows where the existing visualizer is *more* capable than the reference requires. The recurring "new work" is (1) a crisp instanced-line/SDF SceneGraph primitive in normalized space and (2) discipline — palette identity per section, quantization to the BPM grid, and aggressive negative space. The second is a craft/UX problem, addressed in [06-roadmap](06-roadmap.md), not a rendering problem.

---

## (b) Shader Technique Catalog

These are the GPU techniques the modules above are built from. "Already in `Shaders.metal`?" is verified against the actual ~4,770-line shader file (`Makinect/Visualizations/Shaders.metal`) and the two-pass render path in `MetalKinectView.swift` (visualizer → offscreen → `common_post_fs` post-FX).

| Technique | What it does | Used for | Already in `Shaders.metal`? |
|---|---|---|---|
| **2D SDFs** | Signed-distance functions for lines, circles, polygons; exact analytic edges, resolution-independent. | Beam edges, geometric primitives, crisp shapes. Technique reference: [iquilezles.org/articles/distfunctions2d](https://iquilezles.org/articles/distfunctions2d/). | **Partial.** SDF math is used in existing visualizers; needs a consolidated reusable 2D-primitive library for the SceneGraph. |
| **Additive blending** | Light accumulates rather than occludes — overlapping beams get brighter, the physical truth of projected light. | The core "beams of light" feel; starburst overlaps. | **Yes** — additive paths exist in particle/light visualizers; standardize as the SceneGraph default blend mode. |
| **Bloom / glow (Kawase / Gaussian)** | Multi-tap blur of bright regions to halo the beams; sells "light in haze." | Every beam, fan, and burst. Apple `MetalFX` is available for high-quality upscale/bloom (Apple SDK). | **Yes** — glow is a universal knob (`glowMul` in `VisualizationCommonParams.swift`); refine into a dedicated Kawase pass for the beam look. |
| **HDR / ACES tonemap** | Filmic tone-mapping so bright additive stacks don't clip to flat white; keeps color in the highlights. | Preventing washed-out blowouts on dense climaxes (2:40). | **Yes** — ACES tonemap is present (verified: 38 references to `ACES`/`aces` in the shader file). |
| **Polar-coordinate transforms** | Cartesian↔polar mapping for radial/kaleidoscopic symmetry. | Radial spokes, sunbursts, mandala/kaleidoscope. | **Yes** — used by `SandMandala` / `StainedCathedral`; factor into a shared helper. |
| **Domain repetition** | Tile/mirror UV space to repeat a single primitive into a lattice cheaply. | Beam matrices, tunnels, symmetric fans. | **Partial.** Implicit in tunnel/mandala shaders; promote to an explicit SceneGraph operator. |
| **Feedback / trails** | Blend prior frame back in for persistence-of-vision trails — mimics how a galvo's fast scan reads as a solid line. | Lissajous/scan paths, comet-tail beams. | **Partial.** The two-pass offscreen architecture in `MetalKinectView.swift` makes a feedback buffer straightforward; not yet a first-class trail layer. |
| **Instanced line rendering** | Draw thousands of GPU line instances in one pass for razor-crisp beams. | The defining "sharp beam" primitive; the whole point of the aesthetic. | **No — primary net-new render code.** Existing line work is procedural-in-shader; a true instanced-geometry line pipeline is the main new lower-level piece. Medium. |
| **fbm noise** | Fractal Brownian motion for organic drift, haze, modulation. | Beam jitter, haze backdrop, slow drift in the intro. | **Yes** — `fbm` plus `hash21` / `noise2` helpers are present (verified). |
| **Beat / onset-driven uniforms** | Feed audio features into shaders as per-frame uniforms; the binding that makes anything react. | Every reactive module — the entire engine depends on this. | **Yes** — the whole `AudioEngine.swift` → `VisualizerInputs` → shader-uniform path already exists and ships in 38 visualizers. This is solved. |

The honest read: of ten core techniques, seven are fully present, two are partial (consolidation/promotion work, not invention), and exactly **one** — true instanced-line geometry for crisp beams — is meaningfully net-new low-level render code. That is a remarkably small unproven surface for "build a laser-show engine."

---

## (c) Open-Source Dependency Table

**Policy first, because it gates the product:** *We learn techniques from anywhere; we ship only permissively- or commercially-licensed code.* A technique (an SDF formula, a bloom kernel, a sync model) is an idea and free to learn. A *file of code* carries its license with it. Shadertoy and LYGIA are extraordinary to study and **not** shippable as-is in a commercial product. When in doubt, we re-implement the technique from our own understanding in our own code under our own license. This distinction is the difference between a defensible product and a license violation.

| Library | What it gives us | License | Commercial verdict | Link |
|---|---|---|---|---|
| **ISF + ISF-for-Metal** (VIDVOX) | 200+ open shaders and an open-sourced Metal renderer; our primary shader-interop format. | Open source, free for commercial + noncommercial | ✅ **Ship-safe.** Primary recommended shader interop. | [isf.video](https://isf.video/) · [github.com/vidvox/isf](https://github.com/vidvox/isf) · [docs.vidvox.net/opensource](https://docs.vidvox.net/opensource/) · [isf-for-metal](https://vdmx.vidvox.net/blog/isf-for-metal) |
| **Inigo Quilez SDF / raymarch articles** | The canonical technique reference for 2D/3D distance functions and raymarching. | Knowledge/reference (not a code-license dependency) | ✅ **Free to learn from**; we write our own implementations. | [iquilezles.org/articles/distfunctions2d](https://iquilezles.org/articles/distfunctions2d/) |
| **Syphon** | macOS inter-app GPU video output (frame-sharing to other apps/displays). | Simplified BSD | ✅ **Ship-safe.** macOS video-out path. | [github.com/Syphon/Syphon-Framework](https://github.com/Syphon/Syphon-Framework) |
| **OSCKit** (Swift) | OSC messaging for control/interop (cue triggers, external mapping UIs). | MIT | ✅ **Ship-safe.** | [github.com/orchetect/OSCKit](https://github.com/orchetect/OSCKit) |
| **Apple Accelerate / vDSP, MetalKit, MetalFX** | The DSP audio brain (FFT, etc.), Metal rendering, and high-quality bloom/upscale. | Apple SDK | ✅ **Ship-safe** (already the backbone of `AudioEngine.swift` + render path). | Apple Developer SDK |
| **LYGIA shader library** (P. González Vivo) | Large multi-language (incl. Metal) shader helper library. | Prosperity License (free non-commercial; commercial needs paid Patron license) | ⚠️ **Prototype-OK; paid for product**, or re-implement the helpers we need. | [github.com/patriciogonzalezvivo/lygia](https://github.com/patriciogonzalezvivo/lygia) · [lygia.xyz](https://lygia.xyz) |
| **NDI SDK** | Network video output (cross-platform; the LED/projection-wall path beyond local Syphon). | Free but proprietary terms (branding/redistribution constraints) | ⚠️ **Usable but proprietary** — must honor branding/redistribution terms; review before bundling. | NDI SDK terms |
| **Ableton Link** | Network tempo/beat sync for sample-accurate show timing with DJ/live rigs. | Dual GPLv2+ / proprietary | ⚠️ **Closed product must license the proprietary edition from Ableton.** | [github.com/Ableton/link](https://github.com/Ableton/link) · [LICENSE.md](https://github.com/Ableton/link/blob/master/LICENSE.md) |
| **Shadertoy code** | Vast catalog of effects to study. | Default CC BY-NC-SA 3.0 | ⚠️ **Reference / learning ONLY — not shippable.** We re-write our own. | [shadertoy.com/terms](https://www.shadertoy.com/terms) |

Net effect on the product: the **entire core render and audio stack ships on permissive/Apple licenses** (Apple SDKs, ISF, Syphon, OSCKit). The ⚠️ items are all at the *edges* (network sync, network video-out, optional helper libraries) and each has a clean path: license the proprietary edition (Link, NDI), pay the Patron tier (LYGIA), or re-implement the technique ourselves (Shadertoy/LYGIA helpers). None of them block a shippable v1, and the ones that matter for a paid product (Link, NDI) are budget line-items, not legal landmines.

---

## (d) Can We Actually Build This?

### The confidence case (visuals: high)

Makinect today is a mature macOS Swift+Metal audio-reactive engine shipping **38** distinct audio-reactive visualizers (verified: 38 `VisualizationKind` cases in `Makinect/Visualizations/Visualizer.swift`). Several of those are *categorically harder* than the entire visual vocabulary of the INZO reference:

- **Raymarched 3D fractals** — `MandelbulbAviary` raymarches an animated Mandelbulb. A laser fan is a handful of lines; a Mandelbulb is a per-pixel iterated 3D distance field. We already ship the hard one.
- **Real fluid simulation** — `StableFluids` runs a Navier-Stokes-style solver on the GPU. The reference video contains *zero* fluid simulation.
- **65,536-particle GPU swarms** — `ParametricSwarm` choreographs up to 65k particles. The densest starburst in the reference is a tiny fraction of that budget.

And underneath all of it is a **production-grade DSP audio brain** (`AudioEngine.swift`): 8-band log FFT, spectral-flux onset detection, YIN pitch, chromagram chord, autocorrelation BPM, Krumhansl-Schmuckler key, and BS.1770 LUFS — running on the audio render thread with atomic snapshotting and ~1–2 frame latency. The "react to the music" half of "audio-reactive light show" is *already solved at a higher fidelity than most commercial visualizers ship with.*

So the logic is straightforward: **the geometric laser aesthetic is strictly lower complexity than capabilities we already ship.** The render techniques in section (b) are 70% present and 100% proven-adjacent; the visual modules in section (a) have no unproven-capability rows. Confidence on *making it look right* is high. The single genuinely net-new render piece — instanced-line geometry for crisp beams (section b) — is a well-understood, bounded task, not research.

### Honest risk register

Confidence on visuals does **not** transfer to the product as a whole. The hard parts are deliberately *not* the shaders. Stack-ranked by how much they could hurt us:

| Risk | Severity | Why it's the real work | Mitigation / where addressed |
|---|---|---|---|
| **Show-control + timeline/cue system** | **High** | A reactive engine is easy; an engine that holds a *composed* show — section-locked palettes, a cue timeline, disciplined blackouts, the three-timescale sync of [01-video-analysis](01-video-analysis.md) — is a real product with real UX. This is where most "audio-reactive" tools stay toys. | Foregrounded build in [06-roadmap](06-roadmap.md). Reuse `MKAppState.swift` scene/cue infra and `MKPersistence.swift` as the starting substrate. |
| **AI choreographer (Proposal C)** | **High / research** | The offline AI scorer that ingests a track and emits an *editable* choreography score (color arcs, energy curve, negative-space map, geometry selection on the BPM grid) is the genuinely novel, defensible, and *unproven* part. Product/UX risk here is far greater than any shader risk. | This is the unfair advantage and also the biggest unknown — scoped explicitly in [04-proposals](04-proposals.md) (C) and [06-roadmap](06-roadmap.md). AI stays *out* of the live loop (latency truth); it authors a score a deterministic engine performs. |
| **Negative-space discipline (craft)** | **Medium-High** | The reference's perceived sharpness is mostly *restraint* — hard transients plus disciplined silence. An engine that reacts to everything smears the three timescales into mush. This is an authoring/defaults problem, and it's easy to get wrong. | Treat blackout/strobe (section a) and section-locked palettes as first-class authored layers, not afterthoughts. Bias defaults toward restraint. See [01-video-analysis](01-video-analysis.md). |
| **Ableton Link / NDI licensing** | **Medium** | Both are ⚠️ for a closed commercial product (Link's proprietary edition; NDI's proprietary terms). Real money, real terms review — but solvable. | Section (c). Budget line-items, not blockers. Local Syphon (BSD) ships first; network sync/out follow once licensing is cleared. |
| **macOS / Metal market cap** | **Medium** | The pro live-visual world is Windows-centric (disguise / Resolume / Notch / MadMapper). A macOS-only engine has a smaller addressable market and won't displace the incumbents head-on. | Strategic stance from [04-proposals](04-proposals.md): **build something new, don't compete with Resolume head-on.** The unfair advantage (body-tracking + AI-scored geometric sound-to-light) is what justifies the platform, not feature parity. |
| **Screen approximates, never replicates, a galvo** | **Low (but be honest)** | A real RGB galvo draws razor lines via persistence-of-vision at ~30–65k pts/sec with physical haze and near-infinite contrast. An LED wall / projector is pixels with finite contrast and bloom that's *rendered*, not optical. We can get *strikingly close* and arguably more flexible — but we should never claim pixel-for-pixel laser replication. | Set expectations honestly (output target is LED/projection by design — see [04-proposals](04-proposals.md)). Lean into what *raster* does better: arbitrary color, fills, video, body-tracking compositing. |

### Bottom line

Approve the visual catalog with high confidence: **everything in sections (a) and (b) is either already shipping in Makinect or a bounded, well-understood extension of code that ships today.** The licensing in section (c) is clean for a v1 and budgetable for a paid product. The thing to scrutinize hard in the approval conversation is **not** whether we can render beams — we obviously can — but whether we will invest in the show-control timeline and the AI choreographer that turn a reactive toy into a composed, defensible product. That is where the work, the risk, and the unfair advantage all live. The roadmap in [06-roadmap](06-roadmap.md) sequences it accordingly.

---

## Sources

- INZO – "Overthinker" (Unofficial 4K Laser Show) by Vox Daemon: https://www.youtube.com/watch?v=UVaobBtZU2w
- ISF (Interactive Shader Format) / VIDVOX: https://isf.video/ · https://github.com/vidvox/isf · https://docs.vidvox.net/opensource/ · https://vdmx.vidvox.net/blog/isf-for-metal
- Inigo Quilez — 2D distance functions: https://iquilezles.org/articles/distfunctions2d/
- Syphon Framework (Simplified BSD): https://github.com/Syphon/Syphon-Framework
- OSCKit (MIT): https://github.com/orchetect/OSCKit
- LYGIA shader library (Prosperity License): https://github.com/patriciogonzalezvivo/lygia · https://lygia.xyz
- Ableton Link (dual GPLv2+/proprietary): https://github.com/Ableton/link · https://github.com/Ableton/link/blob/master/LICENSE.md
- Shadertoy terms (CC BY-NC-SA 3.0 default): https://www.shadertoy.com/terms

*Makinect codebase references (verified against the repo): `Makinect/Visualizations/AudioEngine.swift`, `Visualizer.swift` (38 `VisualizationKind` cases), `MetalKinectView.swift`, `Shaders.metal` (~4,770 lines; `hash21`/`noise2`/`fbm`, `hsv2rgb`/`rgb2hsv`, ACES tonemap, `common_post_fs`), `VisualizationCommonParams.swift` (6 universal knobs), `MKAppState.swift`, `MKPersistence.swift`.*
