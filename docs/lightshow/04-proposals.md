# Architecture Proposals — A, B, C, and the Chosen Hybrid (D = A + C)

Part of the docs/lightshow series — see [00-README](00-README.md). Read alongside [05-critique](05-critique.md) (where these proposals get stress-tested), [06-roadmap](06-roadmap.md) (how D ships in phases), and [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md) (the geometric vocabulary the engine must render).

> **TL;DR** — Four ways to turn Makinect into a festival-grade, audio-reactive *light show* engine that reproduces the [INZO "Overthinker" laser aesthetic](https://www.youtube.com/watch?v=UVaobBtZU2w) as a screen/projection-rendered geometric vocabulary. **A** = build our own projection engine. **B** = lean on TouchDesigner (demoted to interop). **C** = an AI choreographer that scores a track offline + a deterministic live performer. **D = A + C** is the recommendation: A's render layer and C's score are *one product*, and the body-tracking + AI-scored sound-to-light combination is the defensible, unfair-advantage wedge. B survives only as an escape hatch.

This is the core engineering document. It presents all four proposals, then foregrounds D. The premise everything rests on — established in the project grounding and unpacked in [05-critique](05-critique.md) — is the **three-timescale sync model**:

1. **Structural backbone** — palette + pattern *family* change on section boundaries (intro / build / drop / breakdown).
2. **Rhythmic layer** — scan motion + beam-count pulse on the BPM grid.
3. **Transient layer** — sharp cuts/flashes on individual kicks/snares.

The perceived "sharpness" of a great laser show is the transient layer being **tight** and the negative space being **disciplined**: fire hard on the hit, then get out of the way. Any architecture that reacts to *everything* smears all three timescales into mush. Every latency budget below is therefore graded against one number: **how many milliseconds from a kick transient to photons changing on the wall.** If that exceeds ~one to two frames, the show feels late and the craft is lost.

---

## Latency truth (the constraint that picks the architecture)

Before the proposals, the hard constraint, because it eliminates entire designs:

- Makinect's existing DSP path — 8-band log FFT + spectral-flux **onset** + autocorrelation BPM in [`Makinect/Visualizations/AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift) — produces an onset boolean with **~1–2 frame latency (16–33 ms @ 60 Hz)**. That is the sub-frame transient path. It already exists and already works.
- ML/online beat-trackers (e.g. madmom's online DBN) run at **~100–200 ms latency** ([TISMIR](https://transactions.ismir.net/articles/10.5334/tismir.189), [open-source beat-detection rundown](https://biff.ai/a-rundown-of-open-source-beat-detection-models/)) — **too slow** for the transient layer. They're fine for *labelling structure*, not for *firing on the hit*.
- Generative / diffusion AI **in the live render loop is not viable at <20 ms.** AI's correct job is offline or near-real-time scoring, not per-frame pixel synthesis.
- Sample-accuracy at the pro tier comes from **beat lookahead + a shared clock** — [Ableton Link](https://github.com/Ableton/link) or SMPTE timecode — not from making the analyzer faster. Real-time C++ trackers like [BTrack](https://github.com/adamstark/BTrack) exist if we ever want a second opinion alongside our DSP onset.

**Consequence:** AI never sits on the transient path. DSP onset does. This is the single fact that makes C (and therefore D) coherent rather than hype.

---

## Proposal A — "Makinect Live": build our own projection engine

**Thesis:** Add a crisp vector/geometry render layer on top of Makinect's existing raster shaders, plus network video output and show-control, and we own a festival-grade light-show engine end to end — reusing ~80% of what already ships.

### Architecture (text diagram)

```
            ┌──────────────────────── Makinect Live (A) ───────────────────────────┐
 audio in   │  AudioEngine.swift            VisualizerInputs / CommonParams         │
 ───────────┼─► 8-band FFT ─┐                       │                               │
 (mic/line/ │   onset(bool) ├─► feature snapshot ───┼─► ┌─────────────────────────┐ │
  file)     │   BPM / pitch ┘   (atomic, ~16-33ms)  │   │  RENDER (two layers)    │ │
            │                                        │   │  ┌───────────────────┐  │ │
 Kinect/    │  KinectManager / PoseDetector ─────────┼──►│  │ Raster shaders    │  │ │
 Vision ────┼─► depth + pose ────────────────────────┘   │  │ (Shaders.metal)   │  │ │
            │                                            │  └───────────────────┘  │ │
            │                                            │  ┌───────────────────┐  │ │
            │                                            │  │ SceneGraph (NEW)  │  │ │
            │                                            │  │ beams/lines/polys │  │ │
            │                                            │  │ additive + bloom  │  │ │
            │                                            │  └───────────────────┘  │ │
            │                                            └────────────┬────────────┘ │
            │                                                         ▼              │
            │   Timeline / cue + Ableton Link + timecode ──► OUTPUT: NDI / Syphon ───┼─► LED wall /
            │   (NEW show-control)                           multi-output + mapping  │   projector
            └────────────────────────────────────────────────────────────────────────┘
```

### Data flow (audio → analysis → mapping → render → output)

1. **Audio in** → [`AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift) on the audio render thread.
2. **Analysis** → 8-band FFT, spectral-flux onset, BPM, pitch, chord, key, LUFS; atomic snapshot published to main, exp-smoothed (`band = 0.6*old + 0.4*new`).
3. **Mapping** → features drive `VisualizerInputs` and the six universal knobs in [`VisualizationCommonParams.swift`](../../Makinect/Visualizations/VisualizationCommonParams.swift). For A, the *new* mapping is feature → **SceneGraph** parameters (beam count, fan angle, hue, on/off gate).
4. **Render** → two-pass exactly as today ([`MetalKinectView.swift`](../../Makinect/Visualizations/MetalKinectView.swift): visualizer → offscreen → `common_post_fs` post FX), with the SceneGraph compositing additively into the same offscreen target before bloom.
5. **Output** → NDI/Syphon to a media server / projector / LED processor; multi-output + projection mapping; audio→output latency metering.

### The SceneGraph concept sketch (the heart of A)

The laser look is **not** a shader effect — it's a *vector model* rendered crisply. A SceneGraph is a small, declarative scene description in **normalized space** (`x,y ∈ [-1,1]`, hue/intensity/width per primitive) that the existing audio features animate. It sits **alongside** the raster shaders, not instead of them: raster handles fields/fog/fractal backdrops, SceneGraph handles the razor-edged geometry.

```
SceneGraph (per frame, normalized coords)
├─ Emitters            // sources: 1–2 "projector" origins, like the video's 2 desk units
├─ Primitives
│   ├─ Beam   { origin, angle, length, width, hue, intensity, gate }
│   ├─ Fan    { origin, angleStart, angleEnd, count, hue, intensity }   // violet intro fan
│   ├─ Starburst { center, spokeCount, rotation, hue, intensity }       // drop starbursts
│   ├─ Polygon { verts[], stroke, hue, intensity }                      // squares/triangles
│   └─ Tunnel { ringCount, depth, hue, intensity }                      // beam-matrix tunnel
├─ Modulators          // bind a feature to a property
│   ├─ onset → Beam.gate            (transient layer: fire + decay)
│   ├─ bpmPhase → Starburst.rotation (rhythmic layer)
│   ├─ band[i] → Fan.count          (rhythmic layer)
│   └─ section → palette + active primitive set (structural layer)
└─ NegativeSpaceMask   // a global gate: how much is allowed to be lit right now
```

**Rendering it crisply:** primitives rasterize as **additive** line/triangle geometry (premultiplied, blend-add) into the offscreen target, then a tuned bloom pass (MetalFX or a separable Gaussian in [`Shaders.metal`](../../Makinect/Visualizations/Shaders.metal)) gives the persistence-of-vision glow that sells "beam" instead of "stroke." Anti-aliased line caps + a thin hot core + a wider soft halo is the recipe — detailed in [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md). Crucially, the `NegativeSpaceMask` is a first-class object: *restraint is renderable state*, not an afterthought.

This is **lower complexity than things Makinect already ships** (MandelbulbAviary raymarching, StableFluids). The 38 existing visualizers in [`Visualizer.swift`](../../Makinect/Visualizations/Visualizer.swift) prove the capability; the geometric vocabulary is a simpler render target, not a harder one.

### What we reuse from Makinect

| Need | Reused asset |
| --- | --- |
| Audio features (onset/BPM/FFT/pitch/key) | [`AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift) — production-grade, untouched |
| Two-pass render + post FX | [`MetalKinectView.swift`](../../Makinect/Visualizations/MetalKinectView.swift), `common_post_fs` |
| Shader helpers (hsv/aces/bloom/fbm) | [`Shaders.metal`](../../Makinect/Visualizations/Shaders.metal) |
| Universal knobs + per-effect config | [`VisualizationCommonParams.swift`](../../Makinect/Visualizations/VisualizationCommonParams.swift), e.g. [`ParametricSwarmConfig.swift`](../../Makinect/Visualizations/ParametricSwarmConfig.swift) |
| Scene arming, scene-bar, tap-tempo, panic, snapshots | [`MKAppState.swift`](../../Makinect/MKAppState.swift), [`MKPersistence.swift`](../../Makinect/MKPersistence.swift) |
| Kinect-free audio-reactive compute | [`SyntheticFrameSource.swift`](../../Makinect/Visualizations/SyntheticFrameSource.swift) |
| Mapping-UI pattern to copy | [`MKMidiOutputScreens.swift`](../../Makinect/MKMidiOutputScreens.swift) (UI-only today) |

### Latency budget (A, end-to-end, transient path)

| Stage | Budget |
| --- | --- |
| Audio capture buffer | 5–11 ms |
| FFT + spectral-flux onset (`AudioEngine`) | ~3–6 ms |
| Atomic snapshot → main, exp-smooth | <1 frame (≤16 ms) |
| Feature → SceneGraph mapping | <1 ms |
| Render (raster + SceneGraph additive + bloom) | 4–10 ms (60–120 Hz headroom) |
| NDI/Syphon encode + downstream output | 8–30 ms (NDI worst case; Syphon ~0) |
| **End-to-end (Syphon local)** | **~20–40 ms (1–2 frames)** |
| **End-to-end (NDI to media server)** | **~35–70 ms** |

Onset path stays sub-frame; output transport dominates. Use Syphon for on-machine projection; reserve NDI for multi-machine.

### Build effort / rough timeline

- **SceneGraph MVP** (beams + fan + starburst, additive + bloom, onset/BPM modulators): ~3–4 weeks.
- **Syphon out + single-output mapping:** ~1–2 weeks (Syphon is Simplified BSD, ship-safe — [Syphon-Framework](https://github.com/Syphon/Syphon-Framework)).
- **NDI + multi-output + projection mapping:** ~3–5 weeks ([NDI](https://ndi.video/) terms are proprietary; gate behind a flag).
- **Timeline/cue + Ableton Link + timecode:** ~4–6 weeks (Link is dual-licensed; a closed product must license it — [Link LICENSE](https://github.com/Ableton/link/blob/master/LICENSE.md)).
- **First convincing live show:** ~6–8 weeks. **Full A:** ~3–4 months.

### Risks

- Selling the *beam* look (PoV glow, razor core) is a craft problem — bad bloom reads as "neon stroke," not "laser." Mitigated by the catalog recipe and reference frames.
- Show-control (timeline + Link + timecode) is genuinely new surface area and the most likely to slip.
- NDI/Link licensing must be settled before commercial release (see [05-critique](05-critique.md)).

### Pros / cons

| Pros | Cons |
| --- | --- |
| We own 100% of the IP; no per-machine runtime fees | Most build-from-scratch surface area of any single proposal |
| Reuses ~80% of Makinect | Show-control + output-mapping are net-new and risky |
| Lowest live latency (Syphon path) | On its own it has no *automatic* choreography — operator drives everything |
| macOS-native, Metal-fast | Competes (narrowly) with mature tools on raw output features |

---

## Proposal B — TouchDesigner-centric (DEMOTED to interop/escape-hatch)

**Thesis:** Don't build a renderer — make Makinect a best-in-class *feature + video source* and let [TouchDesigner](https://derivative.ca/) render and output. Fastest path to pixels, but we don't own the stack.

### Architecture (text diagram)

```
 ┌──────────── Makinect (source) ───────────┐        ┌─────────── TouchDesigner ───────────┐
 │ AudioEngine ─► features (onset/BPM/FFT) ──┼──OSC──►│ CHOP network ─► geometry / TOP comp │
 │ Visualizers ─► rendered video ────────────┼──NDI──►│ Movie/NDI In ─► composite           │
 │ Kinect/Vision ─► pose ────────────────────┼──OSC──►│                                     │
 └───────────────────────────────────────────┘        │ DMX Out CHOP / NDI Out ─► fixtures, │
                                                       │ LED, projector                      │
                                                       └─────────────────────────────────────┘
```

### Data flow

Audio → `AudioEngine` features → **OSC** ([OSCKit](https://github.com/SammySmallman/OSCKit), MIT, ship-safe) → TD CHOPs; rendered video → **NDI** → TD TOPs; TD owns mapping + output (its [DMX Out CHOP](https://docs.derivative.ca/DMX_Out_CHOP) speaks Art-Net / sACN / KiNET).

### What we reuse from Makinect

Everything *analysis-side*: [`AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift), [`KinectManager.swift`](../../Makinect/KinectManager.swift), [`PoseDetector.swift`](../../Makinect/PoseDetector.swift). We *discard* our render/output ambitions and let TD render.

### Latency budget (B)

| Stage | Budget |
| --- | --- |
| `AudioEngine` onset | ~3–6 ms |
| OSC over UDP (localhost) | 1–3 ms |
| NDI video Makinect → TD | 16–40 ms |
| TD render + DMX/NDI out | 16–33 ms+ |
| **End-to-end** | **~40–90 ms** |

The extra IPC hops add a frame or two versus A. Tight enough for most shows; not the sharpest possible.

### Build effort / risks / pros-cons

- **Effort:** days to a prototype (OSC bridge is trivial). **Timeline-to-first-show: fastest.**
- **Risks:** per-machine TD licensing; Windows-centric pro world; **we don't own the IP** — the differentiation lives in someone else's app.

| Pros | Cons |
| --- | --- |
| Fastest to a real, mapped, DMX-capable show | No IP ownership; not defensible |
| TD already solves output/mapping/DMX | Per-machine licensing; Windows bias |
| De-risks output features for A | Two apps to run; extra latency |

**Verdict:** keep B *only* as an interop bridge / escape hatch (emit OSC + NDI), never as the product. It de-risks A by letting us validate the feature stream against a known-good renderer.

---

## Proposal C — AI choreographer + DSP performer (the radical split)

**Thesis:** AI is **not** in the live loop. Offline (or near-real-time), it ingests a track and emits an **editable choreography score**; a deterministic <10 ms DSP/GPU engine *performs* that score, and live spectral-flux onsets add micro-reactivity on top. This is the correct, latency-honest use of AI — and the genuinely novel product.

### Architecture (text diagram)

```
  OFFLINE (seconds, not ms)                         LIVE (deterministic, <10ms control)
  ┌───────────────────────────────┐                ┌──────────────────────────────────┐
  │ track (+stems/structure/lyrics)│                │ AudioEngine onset (live) ─┐       │
  │        │                       │                │                           ▼       │
  │        ▼                       │   score.json   │ SCORE PLAYER ─► render params      │
  │ AI CHOREOGRAPHER ──────────────┼───────────────►│  (interpolate cues on clock)      │
  │  • section detection           │  (editable)    │        + onset micro-reactivity   │
  │  • energy curve                │                │                │                   │
  │  • color arcs                  │                │                ▼                   │
  │  • negative-space map          │                │ RENDER (SceneGraph + raster)       │
  │  • pattern/shape on BPM grid   │                │                │                   │
  └───────────────────────────────┘                │                ▼  OUTPUT           │
            ▲ human edits the score                 └──────────────────────────────────┘
```

### The choreography score concept sketch (the heart of C)

The score is the product's crown jewel: a human-editable, version-controllable timeline of intent — *not* baked frames. It's the formalization of the three-timescale model.

```jsonc
// score.json (illustrative)
{
  "bpm": 150, "key": "F# minor",
  "sections": [
    { "t": 0.0,  "name": "intro",     "energy": 0.15,
      "palette": ["violet"],          "patterns": ["single-fan"],
      "negativeSpace": 0.9 },                                 // mostly dark = the statement
    { "t": 30.0, "name": "drop",      "energy": 0.9,
      "palette": ["green","blue","yellow"],
      "patterns": ["starburst","tunnel"],
      "negativeSpace": 0.2 }
  ],
  "colorArcs":   [ { "from": 0, "to": 30, "hue": [270, 120] } ],   // structural
  "energyCurve": [ { "t": 0, "v": 0.15 }, { "t": 28, "v": 0.35 }, { "t": 30, "v": 0.9 } ],
  "negativeSpaceMap": [ { "t": 0, "v": 0.9 }, { "t": 174, "v": 1.0 } ], // 2:54 iris-close → blackout
  "bpmGrid": {                                                  // rhythmic layer
    "patternSelect": [ { "bar": 0, "shape": "fan" }, { "bar": 8, "shape": "starburst" } ],
    "scanSpeed":     [ { "bar": 0, "v": 0.3 }, { "bar": 16, "v": 1.0 } ]
  },
  "transientHints": { "onsetBoost": 0.8, "decayMs": 90 }        // how hard live onsets punch
}
```

- **Color arcs** → structural layer (hue per section/phrase).
- **Energy curve** → density envelope; drives beam count + brightness ceiling.
- **Negative-space map** → *when restraint is mandated* (the 2:54 iris-close → blackout is one keyframe).
- **Pattern/shape select on the BPM grid** → which SceneGraph primitives are active per bar.
- **Transient layer** stays **live**: the Score Player sets the stage; `AudioEngine` onsets fire the actual hits within it. AI proposes; DSP performs; onsets punch.

This is the editable bridge between "AI generated something" and "an operator can trust it on stage."

### Data flow

Offline: track (+ optional stems / structure / lyrics) → AI → `score.json` → human edits. Live: `score.json` + [`AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift) onset → **Score Player** (interpolates cues on an Ableton-Link/timecode clock) → render params → render → output.

### What we reuse from Makinect

- Live onset/BPM for micro-reactivity: [`AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift).
- Cue/snapshot/persistence scaffolding to store and recall scores: [`MKPersistence.swift`](../../Makinect/MKPersistence.swift), [`MKManagerPersistence.swift`](../../Makinect/MKManagerPersistence.swift), scene-bar in [`MKAppState.swift`](../../Makinect/MKAppState.swift).
- C **needs A's renderer** to perform the score (it does not render on its own — see D).

### Latency budget (C)

| Path | Budget |
| --- | --- |
| **Offline** scoring (AI) | seconds–minutes (off the hot path; irrelevant to live feel) |
| **Live** score-cue interpolation | <1 ms (just lerp on a clock) |
| **Live** onset micro-reactivity | ~3–6 ms (`AudioEngine`) + <1 frame publish |
| **Live** render + output | inherits A: ~20–40 ms (Syphon) |
| **End-to-end live transient** | **~20–40 ms (1–2 frames)** — identical to A |

The AI's slowness is quarantined offline. Live latency equals A's, because C performs *through* A.

### Build effort / risks / pros-cons

- **Effort:** Score schema + Score Player: ~2–3 weeks (small, deterministic). AI scorer (section/energy/color/pattern from analysis + LLM reasoning over structure/lyrics): ~6–10 weeks to something useful, ongoing to make it *tasteful*.
- **Risks:** the AI producing *restrained, musical* scores rather than busy ones is the whole ballgame (see [05-critique](05-critique.md)). Needs a great editor UI so humans can fix taste cheaply. Lyric/stem inputs may need third-party services.

| Pros | Cons |
| --- | --- |
| Latency-honest use of AI (offline only) | Useless without A's renderer |
| Editable score = trustworthy + brandable | "Taste" is hard; bad scores look generic |
| The genuinely defensible, novel artifact | Longest path to *autonomous* quality |
| Scores are reusable/sellable content | Needs strong editor UX |

---

## Proposal D — HYBRID = A + C (CHOSEN, foregrounded)

**Thesis:** A's projection engine and C's AI scorer are not two products — they are **one**. A renders; C decides *what* to render and *when to hold back*; live DSP onsets punch the hits. Add body-tracking (Kinect/Vision) on top and you have a sound-to-light engine no incumbent has: **AI-scored, geometry-sharp, body-aware, macOS-native.** B is the escape hatch, not the plan.

### Why A and C compose into ONE product

C is a **brain with no hands**; A is **hands with no brain**. C emits an editable `score.json`; A's **SceneGraph** is exactly the set of primitives the score selects ("starburst," "fan," "tunnel," "polygon"); A's `NegativeSpaceMask` is exactly what C's `negativeSpaceMap` drives. The score's three-timescale structure maps one-to-one onto A's modulators:

```
        ┌──────────────── Makinect Live + AI Choreographer (D) ────────────────────┐
        │                                                                            │
 OFFLINE│  track ─► AI CHOREOGRAPHER ─► score.json (editable in our timeline UI)     │
        │                                   │ structural: palette + pattern family   │
        │                                   │ rhythmic:   BPM-grid pattern + scan     │
        │                                   │ restraint:  negative-space map          │
        └───────────────────────────────────┼───────────────────────────────────────┘
                                             ▼
        ┌──────────────────── LIVE (deterministic, <10ms control) ─────────────────┐
 audio ─┼─► AudioEngine onset/BPM ─┐                                                 │
 Kinect/│                          ▼                                                 │
 Vision─┼─► pose ───► SCORE PLAYER (cues on Ableton-Link/timecode clock)             │
        │              │   + live onset micro-reactivity (transient layer)           │
        │              │   + body-tracking modulators (pose → beam origin/gate)      │
        │              ▼                                                              │
        │   SceneGraph (beams/fans/starbursts/polys/tunnels) ⊕ raster shaders        │
        │              │  additive + bloom  →  offscreen → common_post_fs            │
        │              ▼                                                              │
        │   OUTPUT: Syphon (local) / NDI (network) → LED wall / projector            │
        │                                                                            │
        │   ── ESCAPE HATCH (B) ──► also emit OSC + NDI to TouchDesigner if needed ──┼─►
        └────────────────────────────────────────────────────────────────────────────┘
```

### The body-tracking + AI-score unfair advantage

No mainstream visual tool ships **AI choreography + skeletal body input + geometry-sharp output** in one box. Makinect already has the body half — Kinect v2 depth ([`KinectManager.swift`](../../Makinect/KinectManager.swift)) and Apple Vision pose ([`PoseDetector.swift`](../../Makinect/PoseDetector.swift)). In D, pose becomes a *live modulator* in the SceneGraph: a performer's hands can anchor beam origins, a raised arm can open the negative-space gate, a body silhouette can mask a starburst. The AI score sets the *intent*; the body makes it *interactive*. That pairing — scored intent + live body — is the moat. We are explicitly **not** competing with Resolume on raw compositing; we're shipping a category they don't have.

### Data flow (D, end to end)

1. **Offline:** track (+ optional stems/structure/lyrics) → AI choreographer → `score.json` → operator edits in the timeline UI.
2. **Live analysis:** [`AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift) onset/BPM + [`KinectManager`](../../Makinect/KinectManager.swift)/[`PoseDetector`](../../Makinect/PoseDetector.swift) pose.
3. **Mapping/score:** Score Player interpolates cues on a Link/timecode clock; live onsets + pose add micro-reactivity.
4. **Render:** SceneGraph (additive + bloom) composited with raster shaders via the existing two-pass in [`MetalKinectView.swift`](../../Makinect/Visualizations/MetalKinectView.swift).
5. **Output:** Syphon/NDI → LED/projector; optional OSC+NDI to TD (B escape hatch).

### What we reuse from Makinect

D reuses **everything A and C reuse, combined** — the full audio brain ([`AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift)), the two-pass renderer ([`MetalKinectView.swift`](../../Makinect/Visualizations/MetalKinectView.swift)) and shader helpers ([`Shaders.metal`](../../Makinect/Visualizations/Shaders.metal)), the six universal knobs ([`VisualizationCommonParams.swift`](../../Makinect/Visualizations/VisualizationCommonParams.swift)), cue/scene/persistence infra ([`MKAppState.swift`](../../Makinect/MKAppState.swift), [`MKPersistence.swift`](../../Makinect/MKPersistence.swift), [`MKManagerPersistence.swift`](../../Makinect/MKManagerPersistence.swift)), the MIDI-mapping UI pattern ([`MKMidiOutputScreens.swift`](../../Makinect/MKMidiOutputScreens.swift)) as the basis for a patch/mapping editor, body input ([`KinectManager.swift`](../../Makinect/KinectManager.swift), [`PoseDetector.swift`](../../Makinect/PoseDetector.swift)), and Kinect-free compute ([`SyntheticFrameSource.swift`](../../Makinect/Visualizations/SyntheticFrameSource.swift)). The only net-new code is the SceneGraph, the score schema + player, network output, and show-control — and even those reuse existing patterns.

### Latency budget (D, transient path)

D's live path **equals A's** because the AI is quarantined offline:

| Stage | Budget |
| --- | --- |
| Audio capture buffer | 5–11 ms |
| `AudioEngine` onset | ~3–6 ms |
| Snapshot → main, exp-smooth | ≤16 ms |
| Score-cue lerp + onset + pose modulation | <2 ms |
| Render (SceneGraph + raster + bloom) | 4–10 ms |
| Output (Syphon local / NDI network) | ~0–8 ms / 16–40 ms |
| **End-to-end (Syphon)** | **~20–40 ms (1–2 frames)** |
| **End-to-end (NDI)** | **~35–70 ms** |
| AI scoring | **offline, seconds — off the hot path** |

### Build effort / rough timeline

Sequenced so each phase ships a usable thing (full plan in [06-roadmap](06-roadmap.md)):

1. **SceneGraph + Syphon out** (A core) — ~5–6 weeks → first sharp, beam-look live show, operator-driven.
2. **Score schema + Score Player + onset micro-reactivity** (C live half) — ~3 weeks → scores perform deterministically.
3. **Timeline editor UI + Ableton Link/timecode** — ~4–6 weeks → editable, clock-locked shows.
4. **AI choreographer** (offline scorer) — ~6–10 weeks, iterative → autonomous first drafts.
5. **Body-tracking modulators + NDI/multi-output/mapping** — ~4–6 weeks → the moat + venue-grade output.

**First convincing D demo: ~8–10 weeks. Defensible product: ~5–7 months.**

### Risks

- Largest total scope of the four — but phased so value lands early (see [06-roadmap](06-roadmap.md)).
- Licensing must be settled for a commercial product: Ableton Link (dual-license — [LICENSE](https://github.com/Ableton/link/blob/master/LICENSE.md)), NDI (proprietary terms), and **no shipping** CC-BY-NC Shadertoy or Prosperity-licensed [LYGIA](https://github.com/patriciogonzalezvivo/lygia) code — prefer [ISF](https://isf.video/) (free for commercial use). Full table in [05-critique](05-critique.md).
- AI "taste" risk is inherited from C; mitigated by the editable score + a strong editor.

### Pros / cons

| Pros | Cons |
| --- | --- |
| One coherent product; A and C reinforce each other | Largest overall build scope |
| Body-tracking + AI-score = a category incumbents lack | Multiple licenses to clear before sale |
| Live latency identical to A (AI is offline) | AI taste is an ongoing investment |
| Reuses ~80%+ of Makinect | Show-control remains the riskiest subsystem |
| B remains a no-regret escape hatch | — |

---

## Decision matrix

Scored 1–5 (5 = best for that criterion). "Time-to-first-show" is inverted so 5 = fastest.

| Criterion | A | B | C | **D = A+C** |
| --- | :-: | :-: | :-: | :-: |
| Ownership / IP | 5 | 1 | 4 | **5** |
| Time-to-first-show (5 = fastest) | 3 | 5 | 2 | **3** |
| Fidelity (sharpness/sync to the reference) | 4 | 3 | 4 | **5** |
| Product defensibility | 3 | 1 | 5 | **5** |
| Build risk (5 = lowest risk) | 3 | 5 | 3 | **3** |
| Market size / reach | 3 | 3 | 4 | **5** |
| **Total** | **21** | **18** | **22** | **26** |

### Recommendation: **D (A + C)**

A alone owns the IP but has no brain; C alone has the brain but no hands; B is fast but unownable. **D fuses A's hands and C's brain into one product, inherits A's sub-frame live latency, and adds the body-tracking + AI-score moat no incumbent ships.** B stays in the box as an OSC/NDI escape hatch that de-risks output. Build it in the phases above so the sharp, beam-look live show (A core) is shipping within ~6 weeks while the AI choreographer matures behind it.

Next: [05-critique](05-critique.md) stress-tests these claims (especially AI taste and licensing); [06-roadmap](06-roadmap.md) turns D into a dated plan; [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md) specifies the geometric vocabulary the SceneGraph must render.

---

## Sources

- INZO – "Overthinker" (Unofficial 4K Laser Show), Vox Daemon — https://www.youtube.com/watch?v=UVaobBtZU2w
- Online beat-tracking latency (madmom / DBN) — https://transactions.ismir.net/articles/10.5334/tismir.189
- Rundown of open-source beat-detection models — https://biff.ai/a-rundown-of-open-source-beat-detection-models/
- BTrack (real-time C++ beat tracker) — https://github.com/adamstark/BTrack
- Ableton Link (dual GPLv2+/proprietary) — https://github.com/Ableton/link · license: https://github.com/Ableton/link/blob/master/LICENSE.md
- Syphon Framework (Simplified BSD, commercial-ok) — https://github.com/Syphon/Syphon-Framework
- NDI (network video; proprietary terms) — https://ndi.video/
- OSCKit (Swift, MIT) — https://github.com/SammySmallman/OSCKit
- TouchDesigner — https://derivative.ca/ · DMX Out CHOP — https://docs.derivative.ca/DMX_Out_CHOP
- ISF (Interactive Shader Format; free for commercial use) — https://isf.video/
- LYGIA shader library (Prosperity license; paid for commercial) — https://github.com/patriciogonzalezvivo/lygia
- Makinect source: [`AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift), [`Visualizer.swift`](../../Makinect/Visualizations/Visualizer.swift), [`MetalKinectView.swift`](../../Makinect/Visualizations/MetalKinectView.swift), [`Shaders.metal`](../../Makinect/Visualizations/Shaders.metal), [`VisualizationCommonParams.swift`](../../Makinect/Visualizations/VisualizationCommonParams.swift), [`SyntheticFrameSource.swift`](../../Makinect/Visualizations/SyntheticFrameSource.swift), [`MKAppState.swift`](../../Makinect/MKAppState.swift), [`MKPersistence.swift`](../../Makinect/MKPersistence.swift), [`MKManagerPersistence.swift`](../../Makinect/MKManagerPersistence.swift), [`MKMidiOutputScreens.swift`](../../Makinect/MKMidiOutputScreens.swift), [`KinectManager.swift`](../../Makinect/KinectManager.swift), [`PoseDetector.swift`](../../Makinect/PoseDetector.swift)
