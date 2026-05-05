# Makinect UI Redesign Spec — for Claude Design

> **Drop this entire file into Claude Design.** It contains every screen,
> component, control, data binding, and behavioral rule that exists in the
> current SwiftUI app, plus an opinionated redesign target. Generate
> mocks against the screen specs in §4. Port back via §10.

---

## 1. Context

**App:** Makinect — a macOS Kinect + audio-reactive VJ tool that drives 38 GPU
visualizers, with Vision-framework skeleton tracking, full DSP audio
analysis (waveform / 8-band FFT / spectrogram / pitch / chord / key / BPM /
RMS / LUFS / onset), and a synthetic compute fallback when no sensor is
attached. Built on Metal + SwiftUI + AVAudioEngine. Currently 1100×700
window, single HSplitView shell.

**Why redesign:** the current sidebar-only layout breaks down at scale. 38
visualizers in a flat radio list is unbrowsable. There is no preset system,
no MIDI/OSC bindings, no full-screen output mode for projection mapping,
no live performance UI separation, and the audio + per-viz controls
compete for the same 240 pt of sidebar real estate.

**Target audience:** professional VJs and installation artists driving
projection-mapped pieces in galleries / clubs / theatres. The visual
language should match the gallery references baked into the project
(Refik Anadol, teamLab, UVA, Quayola, Onformative, Daito Manabe).

**Outcome:** a redesigned UI that puts the visualization canvas as hero,
makes the 38 viz library browsable and presetable, surfaces audio and
system monitoring without crowding the controls, and adds a Performance
Mode fit for a live show.

---

## 2. Current UI Survey (as-is, exhaustive)

### 2.1 Window shell
- File: `MakinectApp.swift` + `ContentView.swift`
- Single `WindowGroup`, default size **1100 × 700**, min **960 × 600**
- `HSplitView` — left = visualization canvas, right = SidePanel (240 pt fixed)
- No menu bar customizations, no toolbar, no commands, no keyboard shortcuts

### 2.2 Left pane — Canvas (`ContentView.swift`)
- ZStack over black background
- One of: `MetalKinectView`, NSImage frame, SkeletonOverlayView, idle placeholder

### 2.3 Right pane — `SidePanel.swift` (everything else)
Inside a single ScrollView, GroupBox stack from top to bottom:

| GroupBox | Contents |
|---|---|
| **Stream Mode** | Radio picker: Kinect Live / Synthetic / Segmented |
| **Depth Segmentation** (cond.) | Near/Far sliders 0–4500 mm step 50 |
| **Visualization** | Radio picker — flat list of 38 cases |
| **Depth Range** | Near/Far sliders 0–4500 mm step 50 |
| **Audio Input** | Device dropdown + Refresh button + RMS readout |
| **Audio Monitor** | Embedded `AudioMonitorView` |
| **System** | Embedded `ResourceMonitorView` |
| **Universal Controls** | Audio Reactive toggle, Audio (0–1.5), Speed (0–3), Hue Shift (-0.5–0.5), Saturation (0–2), Brightness (0–2), Glow (0–3), Reset button |
| **Camera Info** (cond.) | Drag/pinch/scroll hint when viz uses 3D camera |
| **Per-Viz** (cond.) | One section per the 38 visualizers — see §2.4 |

### 2.4 Per-visualizer control sections (38 groups)

Each section is a `GroupBox(title)` with `VStack(spacing: 6)` of sliders /
toggles / pickers. Format: `LabeledContent("Name", value: "%.Xf") + Slider`.
Full inventory below — each row is **one persisted property** on its
`@Observable` Config class (one file per visualizer in
`Makinect/Visualizations/<Name>Config.swift`).

> Note: ranges in the UI come from explicit `Slider(in:)` calls in
> SidePanel.swift; defaults are the property initialisers on the Config
> class. `Float` unless noted; ranges are inclusive.

| Visualizer | Controls |
|---|---|
| **Parametric Swarm** | formation (enum picker: auto/sphere/torus/helix/cube/lissajous/attractor/galaxy/orbital), style (segmented: plasma/spark/cyber/ember/vector/glass), particleCount Int=24576, particleSize=3, glowIntensity=1.8, baseHue=0.33, hueSpread=0.04, saturation=0.95, value=0.85, audioReactivity=1, bodyAttraction=1, rotateSpeed=0.18 |
| **Particle Storm** | particleCount Int=200k (1024–262144), curlScale=1.4, accelGain=1, damping=0.93, bodyPull=1, onsetBurst=2, recycleAge=320, baseHue=0.55, hueSpread=1, saturation=0.85, pointSizeBase=2, speedToSize=8, jitterAmount=0.5 |
| **Mercury Storm** | ballCount Int=8, orbitRadius=0.25, ballRadius=0.10, bodyEmit=1.5, baseHue=0.55, streakIntensity=0.4, specularTightness=64, onsetVortex=1 |
| **Mandelbulb Aviary** | fractalPower=8, powerAudioMod=2, raymarchSteps Int=60, fractalHue=0.55, camOrbitSpeed=0.10, birdCount Int=80, birdSize=0.005, birdBodyAttract=0.20, birdHue=0.02 |
| **Body of Petals** | petalSize=0.040, density=0.70, fallSpeed=0.05, bassFall=0.10, hueA=0.96, hueB=0.98, hueC=0.13, saturation=0.55, subSurface=0.6, bodyAvoidance=1, onsetBouquet=1 |
| **Mocap Constellation** | emissionRate=0.05, starLifespan=8, starCoreSize=1500, ringGrowth=0.18, ringWidth=0.012, audioCoupling=0.6, baseHue=0.55, randomizeHue Bool=true |
| **Sand Mandala** | grainCount Int=262144, springK=0.022, damping=0.91, symmetry=8, ringScale=0.45, rotationSpeed=0.0015, onsetMorph=1 |
| **Strand Veil** | strandCount Int=8000, flowScale=0.6, flowAudioMod=0.8, gravity=0.4, strandLength=1, baseHue=0.55, hueSpread=1, audioCoupling=0.7 |
| **Nebula** | marchSteps Int=32 (16–64), densityThreshold=0.45, densityScale=1.5, baseHue=0.5, saturation=0.55, bodyVoid=0.95, noiseScale=1, audioCoupling=1.5 |
| **Smoke God** | marchSteps Int=32, densityThreshold=0.40, densityScale=0.8, litHue=0.10, shadowHue=0.58, saturation=0.5, emberStrength=1, audioCoupling=1.2 |
| **Volumetric Aurora** | fallSpeed=0.08, curtainFreq=8, dropMagnitude=1, starDensity=1, hueA=0.32, hueB=0.85, hueC=0.50, bodyBoost=1.5, trebleShimmer=0.8 |
| **Plasma Sea** | waveScale=4, waveSpeed=1, dispersion=1, deepHueShift=0, litHueShift=0, bodyGlowHue=0.04, audioCoupling=1.2, brightness=1 |
| **Vortex Ring Smoke** | spawnInterval=1.2, riseSpeed=0.0018, swirlFreq=8, saturation=0.5, bodyBoost=1.2 |
| **Filament Cosmology** | marchSteps Int=36, filamentThreshold=0.55, lensStrength=0.4, hueShift=0, audioCoupling=1.5, worleyScale=1.4 |
| **Stable Fluids** | dissipation=0.992, viscosity=0.0001, hueA=0.55, hueB=0.05, saturation=0.85, value=1, autoHueDrift=1 |
| **Dissipative Cells** | cellLifespan=600, driftStrength=0.0008, damping=0.95, minCells Int=12, initialRadius=0.18, mitosisOnOnset Bool=true |
| **Optical-Flow Painter** | viscosity=0.985, motionGate=0.0008, hueA=0.55, hueB=0.05, saturation=0.7, value=0.6, autoHueDrift=1 |
| **Liquid Light Calligraphy** | trailDecay=0.97, viscosity=0.0008, brushRadius=1, perJointHue Bool=true, baseHue=0.55 |
| **Pixel Storm** | sampleCount Int=8, fallSpeed=1, thresholdOffset=0, bodyProtect=1, hueTint=0.6 |
| **Glitch Mosaic** | tileSize=0.018, bassPump=0.025, glitchProbability=0.85, rgbSeparation=0.005, rimIntensity=0.3, onsetStrobe=1 |
| **Impasto Painter** | brushFreq=160, bassPump=80, baseHueShift=0, highlightHueShift=0, bgDesaturation=0.35, audioCoupling=0.6 |
| **3D Point Cloud** | pointSize=4, baseHue=0.60, hueGradient=-0.50, saturation=0.85, bassDisplacement=0.05 |
| **Voxel Sculpt** | voxelScale=0.06, baseHue=0.55, hueSpread=0.15, saturation=0.85, audioCoupling=0.3 |
| **Kinetic Wireframe** | lineThickness=0.0014, explosionMagnitude=0.16, baseHueShift=0, bodyTintHue=0.10, audioCoupling=1 |
| **AR Body Paint** | jointSize=0.06, headSize=0.10, beatBoost=1.2, audioCoupling=4, hueOffset=0, saturation=0.9, falloff=1, trail=1, smoothing=0.4 |
| **Cathedral of Bones** | heartSize=0.025, heartPulse=1, nerveIntensity=1, boneTint=0, strobeIntensity=1, plateWarmth=1, visceraGlow=1, boneThickness=1 |
| **Hyperbolic Tunnel** | swirlBase=0.10, bassSwirl=0.30, foldDepth Int=6, tileSharpness=6, radialFreq=7, onsetGlow=0.5, vignetteScale=1, hueOffset=0 |
| **Iridescent Plumage** | featherSize=0.018, bassGravityComb=1, trebleRuffle=1, hueOffset=0, highlightHueOffset=0.55, gustStrength=1, subSurface=1, audioGlow=1, saturation=1 |
| **Origami Body** | gridSize=0.045, foldSpeed=1, onsetRefold=1, paletteBalance=0.5, paperWarmth=1, inkBleed=1, audioCoupling=1, brushContrast=1 |
| **Stained Cathedral** | sectorCount Int=12, ringCount Int=8, traceryWidth=1, innerGlow=1.5, godRayStrength=1, dustIntensity=0.20, onsetFlash=0.40, bodyHaloHue=0 |
| **Glass Ocean** | refractionStrength=1, causticsIntensity=1, coralHue=0.95, jellyCount Int=8, jellySize=0.04, rimStrength=1, aberration=1, onsetRipple=0.30 |
| **Forest of Light** | pillarSpacing=0.025, swayAmount=1, coreGlow=1, scatterAmount=1, baseHue=0.55, bandSaturation=1, onsetFlash=0.30, audioCoupling=1 |
| **Spectral Ocean** | ringSpeed=1, bassRingSpeed=1, ringDensity=30, crestSharpness=1.5, deepHue=0.55, warmHue=0.05, bodyHaloHue=0.13, onsetWave=0.40 |
| **Liquid Chrome Body** | wobbleBase=0.5, bassEnvBoost=1, trebleEnvBoost=1, fresnelMix=0.65, onsetSpike=1, envHueShift=0, baseTone=0 |
| **Velvet Petal Field** | ringCount Int=4, divisions Int=14, bassBloom=1, baseHue=0.85, saturation=0.85, petalScale=1, stemSway=1, onsetGlow=1 |
| **Magnetic Iron Filings** | lineLength=1, fieldStrength=1, baseHue=0.55, audioCoupling=1, bassHueShift=0.2, onsetPolarityFlip Bool=true, onsetBoost=1, saturation=0.7 |
| **Boids Murmuration** | separation=0.05, alignment=0.04, cohesion=0.012, predator=0.10, bassSeparationBoost=0.04, trebleCohesionBoost=0.02, onsetPredatorBoost=0.30, birdSize=1, flapRate=1 |
| **Memory Palace** | shuffleRate=1, gutterWidth=1, bandSpread=1, paneBleed=1, onsetFlash=0.30, hueOffset=0, saturation=0.7, vignette=1 |

### 2.5 Audio Monitor (`AudioMonitorView.swift`)
Compact VStack(spacing: 8):
1. **Permission/flow banner** — yellow/red/green icon + status; if denied
   shows two `.bordered .controlSize(.mini)` buttons (Request, Open Settings).
   When authorized, "Buffers: <count>" green when > 0; optional red error.
2. **WaveformView** (50 pt) — Canvas polyline, 2048 samples, green 0.85, baseline.
3. **FFTBarsView** (60 pt) — 8 bars 80 Hz–10 kHz, gradient green→yellow→red, white peak-hold markers decaying 0.95×/frame.
4. **SpectrogramWaterfallView** (90 pt) — 256×64 ring, magma ramp (black→indigo→magenta→yellow→white).
5. **NumericReadout** pills × 4 — Pitch ("A4 (440 Hz)"), Chord ("C maj"), Key ("G major"), BPM (with `Tap` micro-button calling `audio.tapTempo()`). Each shows uppercase 9 pt label, 12 pt monospaced value, 2 pt confidence bar (green @ 0.7).
6. **LevelsView** — RMS bar (6 pt, green→yellow→red gradient, 2 pt white peak hold) + LUFS bar (4 pt, cyan 0.85, normalized −70..0 dB).
7. **OnsetLED** — 10×10 pt circle, red filled when onset, 4 pt glow shadow, 0.15 s easeOut animation.

### 2.6 Resource Monitor (`ResourceMonitorView.swift`)
VStack(spacing: 8) — three rows: FPS, CPU, Memory.
- All labels: 9 pt semibold rounded.
- All values: 12 pt monospaced.
- FPS color: green ≥55, yellow 30–55, red <30.
- CPU bar: green→yellow→red gradient, height proportional, scaled by `coreCount`.
- Memory: MB (12 pt) + GB hint (9 pt).

### 2.7 What's missing today
- ❌ No preset/scene save+recall
- ❌ No MIDI / OSC mapping
- ❌ No keyboard shortcuts
- ❌ No full-screen / projection output window
- ❌ No visualizer browser (just radio list of 38)
- ❌ No A/B blending or crossfade between visualizers
- ❌ No timeline / cue list
- ❌ No undo / redo
- ❌ No multi-monitor support
- ❌ No touch bar / iPad companion

---

## 3. Redesign Goals & Constraints

**Goals (in priority order)**
1. **Hero canvas.** Visualization fills the screen; chrome is collapsible.
2. **Browseable library.** 38 visualizers presented as a searchable, categorised, thumbnailed grid — not a flat radio list.
3. **Preset system.** Save + recall any global+per-viz state as a named preset; preset bank visible at all times.
4. **Performance Mode.** A live-show layout with macros, A/B deck, crossfader, BPM-locked transitions.
5. **MIDI / OSC mapping.** Right-click any control → "Learn MIDI" / "Map OSC".
6. **Multi-window output.** Detachable, full-screen output for projector / second display.
7. **Audio + System monitoring** as floating, dockable panels — never competing with controls.

**Hard constraints (must preserve)**
- All 38 visualizers' control surface (every property in §2.4) must remain
  accessible.
- Universal Common Params (audio, speed, hue, sat, bri, glow) must remain
  global and override per-viz.
- AudioEngine permission flow + diagnostic banner must remain visible during
  setup; can collapse once authorized.
- Synthetic vs Kinect source selection must remain top-level.

**Soft constraints**
- macOS-native feel: SF Pro / SF Mono fonts, vibrancy, system pickers.
- Dark-first; light theme is a stretch goal.
- 60 fps UI at 1080p; no expensive blurs over the canvas.

---

## 4. Information Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ TitleBar  [Performance ▸]  [● Output] [Preset ▾] [⌘ Search]     │
├──────────────┬──────────────────────────────────┬───────────────┤
│              │                                  │               │
│  LIBRARY     │           CANVAS (hero)          │   INSPECTOR   │
│  (collapsible│                                  │   (collapsible│
│   left rail) │  - viz preview                   │    right rail)│
│              │  - skeleton overlay opt          │               │
│  Categories: │  - drag/orbit/zoom for 3D viz    │  - per-viz    │
│  - Particles │                                  │    controls   │
│  - Volumetric│                                  │  - common     │
│  - Surface   │                                  │    params     │
│  - Optical   │                                  │  - presets    │
│  - Skeletal  │                                  │               │
│  - Capstone  │                                  │               │
│              │                                  │               │
│  Search:     ├──────────────────────────────────┤               │
│  [        ]  │  TRANSPORT BAR                   │               │
│              │  [▶ Source: Kinect ▾] [BPM 124]  │               │
│              │  [Audio meter] [Onset ●] [⚡ FPS] │               │
└──────────────┴──────────────────────────────────┴───────────────┘
```

Three vertical zones:
- **Left rail (Library):** visualizer browser, search, categories. 240 pt default, collapsible to 56 pt icon-only. Hideable entirely.
- **Centre (Canvas + Transport):** the show. Transport strip (40 pt) docked at bottom shows source, BPM, audio level meter, onset LED, FPS.
- **Right rail (Inspector):** active viz controls + global modifiers + preset bank. 320 pt default, resizable. Hideable.

**Floating panels (detachable, draggable, dockable):**
- Audio Monitor (full DSP analyzer)
- System Monitor (CPU/Mem/FPS detailed)
- Skeleton Joint Inspector
- MIDI / OSC Mappings panel

**Modal overlays:**
- First-Run Permission (mic + camera)
- Preset Save dialog
- Settings (devices, output windows, advanced)

**Special modes:**
- **Performance Mode** — full-screen, both rails hidden, keyboard-first macro deck
- **Output Window(s)** — separate borderless windows for projector(s)

---

## 5. Screen Specifications

> Wireframe convention used below: ░ = vibrancy/elevated background, █ = canvas/black, dimensions in points (1 pt = 2 px on Retina).

### Screen 1 — Main / Default Layout

```
┌─────────────────────────────────────────────────────────────────────────┐
│ ░ [≡] Makinect          ⌘K Search        ●Output  Preset: "Show 1" ▾  │ 32 pt
├──────┬───────────────────────────────────────────────┬──────────────────┤
│ ░    │                                               │ ░                │
│      │                                               │  ▾ Active Viz    │
│ All  │ █                                             │                  │
│ ────│  █                                             │  Volumetric      │
│ ★ Pa │   █     [hero canvas — viz renders here]    │  Aurora          │
│ ░ Vo │                                               │  ─────────       │
│ ░ Su │                                               │  Fall Speed      │
│ ░ Op │                                               │  ◯───●────       │
│ ░ Sk │                                               │  0.08            │
│ ░ Ca │                                               │                  │
│      │                                               │  Curtain Freq    │
│ Q:   │                                               │  ◯─────●──       │
│ [▢]  │                                               │  8.0             │
│      │                                               │  ...             │
│ ┌──┐ │                                               │                  │
│ │░ │ │                                               │  ▾ Common        │
│ │  │ │                                               │  Audio  ●──      │
│ │  │ │                                               │  Speed  ─●─      │
│ │  │ │                                               │  Hue   ──●       │
│ │  │ │                                               │                  │
│ │  │ │                                               │  ▾ Presets (3)   │
│ │  │ │                                               │  • Show 1        │
│ │  │ │                                               │  • Drone         │
│ │  │ │                                               │  • Kicker        │
│ │  │ │                                               │                  │
│ ├──┤ │                                               ├──────────────────┤
│ │ ▼│ │                                               │                  │
│ └──┘ ├───────────────────────────────────────────────┤                  │
│      │ ░ [Kinect ▾] BPM 124 [♪──────] ● 60fps [Mon▾]│                  │
│      │                                               │                  │
└──────┴───────────────────────────────────────────────┴──────────────────┘
240 pt              [flex]                               320 pt
```

**Title bar (32 pt):**
- Hamburger / sidebar toggle (≡) — collapses left rail to icon-only.
- App title.
- Search field (⌘K) — full-text over visualizer names + tags + preset names.
- Output button (●) — toggles secondary output window; lit while output is open.
- Preset dropdown — current preset name; dropdown opens recent + Manage…

**Left rail — Library (240 pt default, 56 pt collapsed):**
- Header: "All" + 6 category buttons:
  - **★ Featured** — curated favourites
  - **Particles** — Particle Storm, Sand Mandala, Strand Veil, Mocap Constellation, Parametric Swarm, Magnetic Iron Filings, Boids Murmuration, Body of Petals, Velvet Petal Field
  - **Volumetric** — Nebula, Smoke God, Volumetric Aurora, Filament Cosmology, Mandelbulb Aviary, Vortex Ring Smoke
  - **Surface** — 3D Point Cloud, Voxel Sculpt, Kinetic Wireframe, Origami Body, Stained Cathedral, Forest of Light, Glass Ocean, Liquid Chrome Body, Hyperbolic Tunnel, Iridescent Plumage
  - **Optical** — Optical-Flow Painter, Stable Fluids, Liquid Light Calligraphy, Pixel Storm, Glitch Mosaic, Impasto Painter, Plasma Sea, Spectral Ocean, Dissipative Cells
  - **Skeletal** — AR Body Paint, Cathedral of Bones, Mocap Constellation
  - **Capstone** — Memory Palace, Mercury Storm
- Search field below categories.
- **Visualizer Card** (full width minus 16 pt margin):
  - 60 pt thumbnail — cached 256×144 PNG of the viz, generated on first run via offscreen render
  - 11 pt title
  - 9 pt category badge + ★ if favourited
  - Hover: 0.6→1.0 opacity, subtle scale 1.02
  - Click: switches active viz with crossfade
  - Right-click: Favourite, Snapshot (refresh thumb), Reveal in Finder

**Centre — Canvas:**
- Fills remaining width; 16:9 letterboxed if aspect doesn't match
- Hover for 1 s shows three overlay corners:
  - Top-left: viz title + category
  - Top-right: ⌘ shortcut hint, ⌥-drag = orbit, ⇧-scroll = zoom (3D viz only)
  - Bottom-right: ⌘F = fullscreen, ⌘O = open output window
- Center-click toggles UI chrome (both rails + transport).

**Transport bar (40 pt, docked bottom of canvas):**
- Source picker (Kinect Live / Synthetic / Segmented) — replaces Stream Mode GroupBox
- BPM display + tap micro-button (uses `audio.tapTempo()`)
- Compact horizontal RMS+peak meter (40 × 8 pt) + onset dot
- FPS readout (colour rule from `ResourceMonitorView`)
- Monitor dropdown — opens floating Audio Monitor / System Monitor / Skeleton Inspector

**Right rail — Inspector (320 pt default, resizable 280–480 pt):**
Three collapsible sections, in this order:
1. **Active Viz** — sliders/toggles/pickers for the current viz (per §2.4)
2. **Common** — universal modifiers (audio, speed, hue, sat, bri, glow)
3. **Presets** — current preset list + Save / Save As… / Recall buttons

Slider design: full width minus 16 pt; label above (9 pt), value right-aligned (9 pt mono); track 4 pt; thumb 14 pt circle. Right-click any slider → context menu: "Reset to default", "Learn MIDI…", "Map OSC…", "Lock value".

### Screen 2 — Visualizer Browser (modal grid, ⌘L)

Full-screen overlay (vibrancy 0.95) with a 4×N grid of thumbnails 320×180 pt. Each card shows: thumbnail, title, 1-line description, audio-reactivity bars indicator (B/M/T showing which of bass/mid/treble drives the piece). Filters at top: All / Featured / Particles / Volumetric / Surface / Optical / Skeletal / Capstone. Search bar fuzzy-searches over title + tags + comments. Hover plays a 2 s GIF preview. Click loads viz + dismisses browser.

### Screen 3 — Performance Mode (⌘P, full-screen)

Single window, no rails, no transport. Bottom 120 pt is the **Performance Deck**:
- 8 macro buttons (1–8 keyboard shortcuts) — each binds to a preset
- A/B viz pair with crossfader (left/right arrows = nudge; X = swap)
- Single-knob "Energy" macro — drives audioReactivity, glow, and onsetBoost across all viz
- BPM bar with quarter-note flash; tap-tempo space bar
- Esc returns to Main layout

### Screen 4 — Floating Audio Monitor

Detachable window 360×600 pt. Same structure as current `AudioMonitorView` but
with three additional features:
- **Pin** button (top-right) — keeps panel above main window
- **Compact / Expanded** toggle — compact = waveform + RMS only (180 pt); expanded shows full DSP stack
- **Permission banner** stays at top until authorized, then collapses to a thin status pip

### Screen 5 — Floating System Monitor

Detachable 280×220 pt. Three rows from `ResourceMonitorView` plus:
- 60-second sparkline for FPS (small canvas, 240×40 pt, green/yellow/red banding)
- GPU memory readout (Metal heap size)
- Frame-budget breakdown if a viz exceeds 16.6 ms — show stages timing

### Screen 6 — Skeleton Inspector (floating, 320×400 pt)

- Live 2D stick-figure rendering of `poseDetector.skeletons[0]`
- Per-joint confidence bars (sortable list)
- Joint visibility toggles per viz that consumes joints
- Smoothing alpha slider (0.05–1.0) — overrides per-viz default

### Screen 7 — MIDI / OSC Mappings (modal, ⌘,M)

- Tabbed: **MIDI** | **OSC** | **Tap Tempo**
- MIDI tab: list of currently mapped (Note/CC#) → control pairs; Add → enters Learn mode; status banner pulses when MIDI msg received but unmapped
- OSC tab: server port (default 8000), endpoint pattern (default `/makinect/<viz>/<param>`), allowlist of source IPs
- Each row has a Test fader + Unbind button

### Screen 8 — Preset Manager (drawer or modal, ⌘⇧P)

- Bank of named presets in a 3-column grid; each card shows preset name, last-used timestamp, viz it targets, and 64×36 thumbnail
- Click loads; double-click renames; right-click: Duplicate, Export to .makinectpreset file, Delete
- Top-bar buttons: New, Import, Export Bank…
- A preset stores: visualization (kind), all per-viz config values, common params, segmentation depth, MIDI/OSC bindings (optional)

### Screen 9 — Settings (⌘,)

Tabbed window 720×520 pt:
- **General** — appearance (system / dark / light), default window size, restore on launch
- **Devices** — Kinect (V1/V2 enable, depth range), Audio (input device list with refresh, sample-rate override)
- **Output** — secondary monitor selector, full-screen letterbox / fill / native, output mirror toggle, gamma
- **Performance** — frame target, particle quality (low/med/high → affects ParticleStorm + others), enable Metal validation
- **Privacy** — links to System Settings ▸ Privacy ▸ Microphone / Camera; current TCC status (re-uses `permission` enum)
- **Advanced** — shader hot-reload directory, shader sandbox enable, MIDI/OSC defaults, log level

### Screen 10 — First-Run Permission (modal, dismisses on grant)

Centered card 480×320 pt:
- App icon, hero copy "Welcome to Makinect"
- Two row items, each with status pip:
  - 🎤 Microphone — required for audio reactivity. Status: not yet asked / authorized / denied.
  - 📷 Camera — optional, only used when Kinect isn't available.
- Two buttons: **Grant Microphone** (calls `audio.requestPermission()`), **Maybe Later**
- Diagnostic line below: bundle ID + auth status (today's NSLog content) — one-line, secondary text

### Screen 11 — Output Window (borderless, full-screen optional)

Separate window optionally on a second display. Shows the same canvas as the
main window but at the screen's native resolution, no chrome. Cmd+Shift+F →
toggle full-screen on the output window's screen. Cmd+Shift+M → mirror /
unmirror from main canvas.

### Screen 12 — Empty State (no Kinect + no mic)

Center of main canvas:
- Faint connector graphic
- Title: "No sensor connected"
- Three actions: **Use Synthetic Source** (default), **Refresh USB**, **Open System Settings**

---

## 6. Components Catalog (atoms + molecules)

| Component | Purpose | States |
|---|---|---|
| `LibraryCard` | viz card in left rail | rest, hover, active, dragging |
| `ThumbnailCard` | larger card in browser modal | rest, hover, GIF-preview, active |
| `Slider` (custom) | numeric control | idle, hover, active, midi-armed, midi-mapped, osc-mapped, locked |
| `Toggle` (custom) | bool control | off, on, midi-armed |
| `Picker.menu` | dropdown picker | closed, open |
| `Picker.segmented` | inline picker (≤6 items) | per-segment hover/active |
| `LabeledContent` | "label : value" pair | static |
| `WaveformCanvas` | renders [Float] | live update |
| `FFTBars` | 8 bars w/ peak hold | live |
| `SpectrogramTile` | 256×64 ring magma | live, paused |
| `NumericReadout` | label / value / confidence bar | empty (—), low conf, high conf |
| `OnsetLED` | pulse on onset | idle, flash, error |
| `ResourceRow` | label + value + bar | green / yellow / red |
| `PermissionBanner` | mic/cam status + actions | undetermined, requesting, authorized, denied, restricted |
| `TransportStrip` | bottom dock | live |
| `MacroButton` | performance-mode 1–8 | idle, hover, armed, fired |
| `Crossfader` | A/B mix | idle, dragging |
| `PresetCard` | preset thumbnail + name | rest, hover, active, renaming |
| `MIDIRow` | mapping row | unmapped, learning, mapped |

**Component design rules**
- 4 pt grid for spacing. 8 pt is the canonical inter-row gap.
- 14 pt slider thumb, 4 pt track. Track active fill = system accent (default cyan).
- Disabled controls: 0.4 opacity, no hover effect.
- Right-click (or ⌃-click) on any control opens its context menu.

---

## 7. Visual Design Tokens

**Palette (dark theme baseline):**
- `bg.window` — `#0B0B10` (true near-black)
- `bg.sidebar` — `#15151C` (slight elevation)
- `bg.elevated` — `#1F1F28` (cards / popovers)
- `text.primary` — `#F2F2F7`
- `text.secondary` — `#9C9CB0`
- `text.tertiary` — `#5C5C70`
- `accent` — `#7AE7FF` (cyan, audio-reactive)
- `accent.warm` — `#FFB066` (preset / performance)
- `success` — `#5BD89F`
- `warning` — `#FFD66B`
- `danger` — `#FF6F84`

**Typography:**
- Display: SF Pro Display, 16 pt, semibold
- Title: SF Pro Text, 13 pt, medium
- Body: SF Pro Text, 12 pt, regular
- Caption: SF Pro Text, 9 pt, semibold, tracking +0.5
- Mono: SF Mono, 12 pt, regular (numeric readouts)
- Numeric values: tabular-num feature on

**Spacing scale:** 0 / 2 / 4 / 6 / 8 / 12 / 16 / 24 / 32 / 48 / 64

**Radius:** 4 (atoms), 8 (cards), 12 (modals), 999 (pills)

**Elevation / shadow:**
- Resting: none
- Floating panel: 0 4 16 rgba(0,0,0,0.4)
- Modal: 0 16 48 rgba(0,0,0,0.6)
- Dragging: 0 8 24 rgba(0,0,0,0.5) + 1 px cyan inner stroke

**Motion:**
- Slider thumb: 0.08 s ease-out
- Sidebar collapse: 0.18 s spring(damp 0.85)
- Modal: 0.22 s ease-out fade + 8 pt rise
- Viz crossfade on selection: 0.5 s linear (alpha mix)
- OnsetLED pulse: 0.15 s ease-out

**Audio-reactive UI accents:** the title bar's cyan accent line ramps brightness with `audio.rms` (0.4 → 1.0). When `audio.onset` fires, a 1 px hairline at top of canvas pulses cyan. When `bpmConfidence > 0.6`, the BPM digit flashes on each beat.

---

## 8. Interaction Patterns

**Keyboard shortcuts**
| Shortcut | Action |
|---|---|
| ⌘L | Open Visualizer Browser |
| ⌘K | Focus search |
| ⌘P | Performance Mode toggle |
| ⌘⇧P | Preset Manager |
| ⌘O | Toggle output window |
| ⌘F | Fullscreen current canvas |
| ⌘⇧F | Fullscreen on output display |
| ⌘\ | Toggle left rail |
| ⌘⇧\ | Toggle right rail |
| ⌘⇧M | Mirror output ↔ main |
| ⌘, | Settings |
| ⌘,M | MIDI / OSC mappings |
| Space (perf mode) | Tap tempo |
| 1-8 (perf mode) | Fire macro 1-8 |
| ← → (perf mode) | Crossfade A↔B |
| X (perf mode) | Swap A↔B |
| Esc | Exit perf mode / dismiss modal |

**Mouse / trackpad:**
- Drag in canvas (3D viz only): orbit camera (`Visualizer.handleDrag`)
- Pinch in canvas: zoom (`Visualizer.handleMagnify`)
- Scroll in canvas: dolly (`Visualizer.handleScroll`)
- Drag a Slider up/down (alt-drag): fine-tune (×0.1 sensitivity)
- Right-click any control: context menu (Reset, Learn MIDI, Map OSC, Lock)

**MIDI:**
- "Learn MIDI" mode arms the next-touched MIDI input (Note or CC) and binds it
- LED on mapped controls glows magenta while MIDI message arrives
- Range mapping: `(MIDI 0–127) → (slider min..max)`, with optional curve preset

**OSC:**
- Server listens on UDP 8000 by default
- Address pattern: `/makinect/<viz-rawvalue>/<property>` e.g. `/makinect/Volumetric Aurora/fallSpeed`
- Float values 0–1 normalised into slider range; ints rounded

**Drag-and-drop:**
- Drop preset file (.makinectpreset) onto the window → adds to bank
- Drag a viz card onto another's preset slot → cross-bank copy
- Drag a slider knob to a Performance Mode macro slot → binds macro

---

## 9. State Model & Data Bindings (port-back contract)

The redesigned UI binds to existing `@Observable` classes — **no new model
layer is required**. Each component listed in §6 has an exact data source
already in the codebase:

| UI binding | Source |
|---|---|
| Active viz selection | `KinectManager.visualization: VisualizationKind?` |
| Source picker | `KinectManager.source: InputSource` |
| Camera mode (only when source = Kinect) | `KinectManager.cameraMode: CameraMode` |
| Segmentation depth | `KinectManager.segmentationNearMM`, `segmentationFarMM` |
| Common params | `KinectManager.common: VisualizationCommonParams` (existing) |
| Per-viz controls | `KinectManager.<vizName>: <VizName>Config` (38 existing files) |
| Audio meter | `audio.rms`, `audio.rmsPeak`, `audio.lufs`, `audio.onset` |
| Audio analysis | `audio.bands`, `audio.waveform`, `audio.spectrumColumn`, `audio.pitchHz/.pitchNoteName/.pitchConfidence`, `audio.chordName/.chordConfidence`, `audio.keyName/.keyConfidence`, `audio.bpm/.bpmConfidence` |
| Audio permission | `audio.permission: AudioPermission` (existing enum) |
| Audio diagnostic | `audio.tapCallbackCount`, `audio.lastEngineError` |
| Resource readouts | `resourceMonitor.fps`, `.cpuPercent`, `.memoryMB`, `.coreCount` |
| Skeleton | `poseDetector.skeletons` |
| Available audio inputs | `audio.availableInputs: [AudioInputDevice]` |

**New @Observable classes needed (small):**
- `PresetBank` — owns `presets: [Preset]`, `currentName: String?`, save/load to `~/Library/Application Support/Makinect/Presets/*.json`
- `MIDIBindings` — owns `bindings: [Binding]`, learning state, listens to `MIDIInput`
- `OSCServer` — owns port, bindings, connection state
- `OutputWindowController` — manages secondary `NSWindow`; bound to `KinectManager` so the same `MetalKinectView` content can render to it

These three classes are additive; existing code does not need refactoring.

---

## 10. Implementation Mapping (port-back from Claude Design → SwiftUI)

| Designed screen / component | New / changed files |
|---|---|
| Title bar | `Views/Shell/TitleBar.swift` |
| Left rail (Library) | `Views/Library/VisualizerLibraryView.swift`, `Views/Library/VisualizerCard.swift`, `Views/Library/CategoryFilter.swift` |
| Visualizer thumbnails (offscreen renders) | `Visualizations/ThumbnailRenderer.swift` (new — renders each viz to PNG once) |
| Canvas (existing) | `Views/Shell/CanvasContainer.swift` wrapping current `MetalKinectView` |
| Transport strip | `Views/Shell/TransportBar.swift` |
| Right rail (Inspector) | `Views/Inspector/InspectorPane.swift`, `Views/Inspector/ActiveVizSection.swift`, `Views/Inspector/CommonParamsSection.swift`, `Views/Inspector/PresetsSection.swift` |
| Per-viz control sections | Move existing 38 `private var <name>Section` blocks from `SidePanel.swift` into `Views/Inspector/PerViz/<Name>InspectorView.swift` (1 file per viz, mechanical rename) |
| Browser modal | `Views/Library/VisualizerBrowserView.swift` |
| Performance Mode | `Views/Performance/PerformanceModeView.swift`, `Views/Performance/MacroDeck.swift`, `Views/Performance/Crossfader.swift` |
| Floating Audio Monitor | wrap existing `AudioMonitorView` in `Views/Floating/FloatingAudioWindow.swift` (NSWindow controller) |
| Floating System Monitor | wrap existing `ResourceMonitorView` similarly |
| Skeleton Inspector | new `Views/Floating/SkeletonInspectorView.swift` |
| MIDI / OSC modal | `Views/Settings/MIDIMappingsView.swift`, `Views/Settings/OSCMappingsView.swift` + new `Audio/MIDIInput.swift`, `Audio/OSCServer.swift` |
| Preset manager | `Presets/PresetBank.swift`, `Presets/Preset.swift`, `Views/Presets/PresetManagerView.swift` |
| Settings | `Views/Settings/SettingsView.swift` (tabbed) |
| First-run permission | `Views/Onboarding/FirstRunPermissionView.swift` |
| Output window | `Views/Shell/OutputWindowController.swift` (NSWindowController wrapping MetalKinectView) |

**Files modified (not deleted):**
- `ContentView.swift` — replaces HSplitView with the three-pane shell
- `MakinectApp.swift` — adds keyboard shortcuts via `.commands { … }`, opens output window scene
- `SidePanel.swift` — most content migrates to InspectorPane and Library; keep only legacy fallback or remove entirely once migration complete
- `Makinect.entitlements` — already has audio-input + camera (just shipped)

**No model changes required for visualizers.** Every Config class, AudioEngine
property, ResourceMonitor field is already addressable; the redesign is
pure presentation + new orchestrator classes (PresetBank, MIDIBindings,
OSCServer, OutputWindowController).

---

## 11. Verification

After porting back from Claude Design, the redesign is complete when:

1. **Functional parity** — every property listed in §2.4 is reachable from
   the Inspector (no slider lost). Diff each viz's controls against §2.4.
2. **Permission flow** — fresh install on a clean macOS user shows the
   First-Run modal; clicking "Grant Microphone" triggers the system
   prompt; granting flips `audio.permission` to `.authorized` and the
   modal dismisses. Verify with `tccutil reset Microphone Idontknow.Makinect`.
3. **Library** — all 38 viz cards visible, each shows a thumbnail (run
   `ThumbnailRenderer` once on first launch); search for "aurora" returns
   Volumetric Aurora; clicking switches viz with crossfade.
4. **Presets** — save the current state, switch viz, recall preset; all
   Config values + common params restore exactly.
5. **MIDI mapping** — connect an MPK Mini, hit "Learn MIDI" on Speed
   slider, turn Knob 1; verify slider follows knob; mapping persists across
   app restart.
6. **Output window** — Cmd-O opens a borderless window; Cmd-Shift-F
   full-screens it on the secondary display; both windows render the
   same viz at native resolution; closing either keeps the other alive.
7. **Performance Mode** — Cmd-P enters perf mode; macro buttons 1-8 fire
   presets; spacebar tap-tempo updates BPM; Esc returns to Main.
8. **Audio Monitor floating** — drag the Audio Monitor out of the right
   rail, dock it to the left; resize 280–600 pt; toggle compact mode;
   Pin keeps it above; closing returns it to the dock.
9. **Frame budget** — UI does not push the canvas under 55 fps. Verify
   via Resource Monitor sparkline during heavy preset cycling.
10. **Keyboard shortcut completeness** — every shortcut in §8's table fires
    its action; `⌘?` shows a cheat-sheet popover.

Smoke-test on:
- Apple Silicon laptop, built-in mic, no Kinect → uses Synthetic source, audio works
- Apple Silicon desktop, Kinect v2, external audio interface at 44.1 kHz → both work, no format crash
- Two-display setup → output window flips between displays via Cmd-Shift-M

---

## 12. What to deliver back from Claude Design

For each screen in §5 produce:
- **Layout PNG** at 1× and 2× (Retina) for the default state
- **Annotated wireframe** marking every slider/button/picker with its data binding from §9
- **Dark-mode PSD/Figma source** organised in components from §6
- **Component spec sheet** — for each atom, the resting + hover + active +
  disabled state at 2×
- **Motion notes** — any custom animation beyond §7's defaults

Output bundle as a single `.zip` with the structure:
```
Makinect-UI/
  screens/
    01-main.png  01-main@2x.png  01-main.fig
    02-browser.png …
  components/
    slider.fig  toggle.fig  …
  tokens.json   ← color + typography + spacing tokens (Style Dictionary format)
  README.md     ← copy of §10 mapping + any deviations from this spec
```

The `tokens.json` will be consumed by a new `DesignTokens.swift` generated
file so colors / fonts / spacing stay in sync between Design and code.
