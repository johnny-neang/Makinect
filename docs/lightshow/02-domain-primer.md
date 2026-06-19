# Domain Primer — Light, Geometry, Sound, and Negative Space

Part of the docs/lightshow series — see [00-README](00-README.md). Sibling reading: [01-video-analysis](01-video-analysis.md) (the INZO "Overthinker" laser show, frame by frame) and [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md) (the concrete pattern catalog and how each maps onto Makinect's engine).

> **What this doc is.** A shared vocabulary. Everything else in this series — the proposals, the engine plan, the AI choreographer — assumes you can name what you're looking at when you watch a great laser show and say *why* it works. This primer gives you those names and the physics/perceptual reasons behind them. It is deliberately opinionated: the thesis is that the **craft is mostly restraint**, and the engineering is mostly making **geometry read as emitted light**.

> **Scope reminder.** Our output target is an **LED wall or projector** (an emissive raster surface), not physical galvanometer lasers. The INZO reference *is* real lasers — we are reproducing its **aesthetic** as a geometric visual vocabulary, not its hardware. See [00-README](00-README.md) for the resolved decisions. Physical lasers are a one-line "someday, not now" footnote.

---

## 1. The geometric visual vocabulary

A laser-style show is built from a small alphabet of geometric primitives. The artistry is in *which* one you draw, *when*, and *how empty the rest of the frame is*. Below: each primitive, what it is, and the **audio feature that most naturally drives it**. (The mapping column is the bridge to Makinect's `AudioEngine` features — see [`Makinect/Visualizations/AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift). For the catalog of which existing visualizer covers each, see [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md).)

| Primitive | What it is | Natural audio driver | Where in INZO |
|---|---|---|---|
| **Beam** | A single straight line of light from a source point, drawn edge-to-edge. The atom of the whole language. | Onset / single transient (fire on the hit, then gone). Pitch can set the angle. | Intro single violet beam (`frames/t00-01_intro-single-violet-fan.jpg`) |
| **Beam fan** | Several beams sharing one origin, spread across an angular sweep — a hand of cards from a pivot. | Mid-band energy for width; the fan *opens* as energy rises. | Intro violet fan; breakdown cyan-top / violet-bottom split (~0:55–1:23) |
| **Beam matrix / tunnel** | A dense field of parallel or converging beams reading as a 3D corridor receding to a vanishing point. | Sustained bass/sub energy + BPM-locked scan; the tunnel *pulses* and scrolls on the grid. | First drop tunnels (~0:30–0:55); main-drop green+blue matrix (`frames/t01-14_drop-green-blue-matrix.jpg`) |
| **Starburst** | Beams radiating symmetrically from a central point in all directions — an explosion frozen mid-bloom. | Onset for the *trigger*; broadband RMS / LUFS for the *size* of the bloom. | Buildup purple starburst (`frames/t00-30_buildup-purple-starburst.jpg`); dense multicolor drop bursts (1:23–2:40) |
| **Radial spokes / sunburst** | Evenly-spaced spokes from a hub, often slowly **rotating**. Cousin of the starburst but *ordered* and *static-count* — geometry over chaos. | BPM for rotation rate; structural section for spoke count. Low transient coupling — it's a "held" shape. | Rebuild radial sunburst (`frames/t03-17_radial-sunburst-spokes.jpg`, ~3:17) |
| **Geometric primitives** (square / triangle / polygon) — rotating, nested, exploding | Closed outlined shapes. Power comes from **transformation**: nesting (shape inside shape), rotation, and "exploding" (vertices flung outward on a hit). | Beat grid drives rotation; onset drives the explode/scale-pop; pitch/chord can drive how many sides. | Implied in the angular "V" beams of the rebuild (~3:00–3:50) |
| **Kaleidoscope / mandala** | Radial/mirror symmetry applied to *any* source content, multiplying it into a flower of repeats. Cheap way to turn one beam into a cathedral. | Chord/key for symmetry order; mid-high shimmer for the fine detail. | Symmetric structure throughout the drops; relates to `SandMandala`, `StainedCathedral` |
| **Lissajous & scanning grids** | Parametric curves (x = sin(at), y = sin(bt+δ)) and raster scan-lines — the literal motion path a galvo traces. The "signature" laser squiggle. | Pitch ratios (a:b) map to harmonic intervals; scan speed on BPM. | The scan-speed pulse underlying the beam motion (1:23–2:40) |
| **Particle fields / swarms** | Thousands of independent points with their own motion — looser, organic, less "drawn-line" and more "spray." | High-band energy and onset density; spectral flux scatters them. | Less prominent in INZO (lasers favor lines) but core to Makinect — see `ParticleStorm`, `ParametricSwarm` (up to 65,536 GPU particles) |
| **Fluid / plasma backdrops** | Continuous flowing color fields — smoke, aurora, plasma. The *anti-laser*: soft, no hard edges. | Sub/bass for the slow churn; LUFS for overall brightness. | Not in INZO (lasers are line-only). Useful as a contrasting "breath" layer — `PlasmaSea`, `StableFluids`, `VolumetricAurora`, `SmokeGod` |

**The crucial taxonomy split:** *line-based, hard-edged* primitives (beams, fans, matrices, starbursts, spokes, polygons, Lissajous) are the laser vocabulary. *Field-based, soft* primitives (particles, fluid, plasma) are a different aesthetic. INZO is ~95% line-based. Makinect today is rich in field-based effects and thinner on crisp line-based geometry — which is exactly the gap the new vector/geometry render layer fills (see [00-README](00-README.md) Proposal A and [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md)).

---

## 2. Additive blending, bloom, and HDR tonemap — why geometry reads as *light*

This is the single most important rendering insight, so be precise about it. The reason a beam on screen looks like *emitted light* and not like a painted line is the **compositing math**, not the geometry.

### Additive blending
When two lights overlap in the real world, their intensities **add** — two flashlights on one spot are brighter than one. That's [additive color mixing](https://en.wikipedia.org/wiki/Additive_color): red + green + blue light sum toward white. Subtractive mixing (paint, ink, the [CMY model](https://en.wikipedia.org/wiki/Subtractive_color)) is the opposite — pigments *remove* wavelengths and pile toward muddy brown/black.

In a renderer, additive blending means `dst = src + dst` (often `ONE, ONE` blend factors) instead of the default alpha-over `dst = src·α + dst·(1−α)`. Consequences that matter for the laser look:

- **Overlaps brighten instead of occluding.** Where two beams cross, you get a hot node — exactly what real crossing laser beams do. Alpha-over would just paint one beam on top of the other.
- **Black is the identity element.** Adding to black changes nothing, so the dark background *stays* truly dark and the lines float on it. This is why additive + a black canvas is the natural home of negative space (Section 6).
- **Color builds toward white at the core.** A saturated beam with a bright additive core reads as "glowing," because that's the [veiling-glare/clipping cue](https://en.wikipedia.org/wiki/Bloom_(shader_effect)) our eyes associate with a genuinely bright emitter.

Subtractive/painterly looks (think gouache, ink washes) *cannot* produce this — they get darker and muddier as they overlap, which reads as material, not light. That aesthetic is valid; it's just not this one.

### Bloom / glow
[Bloom](https://en.wikipedia.org/wiki/Bloom_(shader_effect)) is the soft halo around very bright regions. Physically it's light scattering inside the eye and the camera lens; perceptually it's the strongest possible "this thing is *really* bright" signal a display can send, because a monitor can't actually exceed its own max luminance — so it *fakes* extra brightness by bleeding light into neighboring pixels. Implementation: threshold the bright pixels, blur them at several scales, add back. Makinect already does post-process FX in a second pass — see the offscreen → `common_post_fs` path in [`Makinect/Visualizations/MetalKinectView.swift`](../../Makinect/Visualizations/MetalKinectView.swift), and Apple's [MetalFX](https://developer.apple.com/documentation/metalfx) is available for high-quality bloom/upscale. A thin, perfectly sharp beam with a tight bloom halo is the canonical "neon/laser" recipe.

### HDR tonemap
Render in high dynamic range (values can exceed 1.0), then map down to displayable range with a curve like [ACES](https://en.wikipedia.org/wiki/Academy_Color_Encoding_System). Why it matters here: additive overlaps *want* to blow past 1.0, and a good tonemapper rolls those highlights off gracefully (gentle desaturation toward white at the very top) instead of hard-clipping into ugly flat patches. Makinect already ships an ACES tonemap helper in `Makinect/Visualizations/Shaders.metal`. The combination — **additive accumulation in HDR → bloom → ACES rolloff** — is what turns flat geometry into something that reads as luminous on an emissive surface.

> **Rule of thumb:** crisp core + additive accumulation + tight bloom + HDR rolloff = "laser." Soft alpha + subtractive + no bloom = "illustration." The geometry can be identical; the compositing decides which one your brain sees.

---

## 3. LED wall vs projection — which surface suits geometric light

Both are emissive raster targets, but they behave very differently, and **true black** is the deciding factor for this aesthetic.

| Attribute | Direct-view LED wall | Projection (projector + screen) |
|---|---|---|
| **Brightness** | Very high — typically 800–1,500+ nits, outdoor models far higher; readable in ambient light. | Lower effective brightness, measured in lumens spread over area; ambient light washes it out fast. |
| **True black / contrast** | Excellent — an unlit LED is *off* (near-zero emission), so black is genuinely black. | Poor — the projector can't emit "negative light," so black is only as dark as the *unlit screen under ambient light*; contrast collapses in a lit room. |
| **Pixel pitch** | The spacing between LEDs (e.g. P2.5 = 2.5 mm). Smaller pitch = finer detail but much higher cost. Sets minimum viewing distance. | Resolution fixed by the panel (1080p/4K); apparent sharpness depends on throw distance and focus. |
| **Ambient light tolerance** | High — works in daylight/lit venues. | Low — wants a dark room; stray light is the enemy. |
| **Scale & modularity** | Tiles into arbitrary shapes/sizes; heavy, power-hungry, needs rigging. | One device covers a large area cheaply; easy to scale *area* by moving the projector back (at a brightness cost). |
| **Cost** | High up front (per-tile), scales with area. | Low device cost; large surfaces are cheap *if* you control the room. |

**Verdict for the geometric-light aesthetic: LED wall is the better fit, primarily because of true black.** Negative space (Section 6) is half the craft, and negative space only exists if "off" is genuinely dark. On a projector in anything but a blacked-out room, your beautiful single violet beam floats on a grey haze instead of a void, and the whole restraint-based design language collapses. Projection is the pragmatic/affordable path and is fine in a controlled dark venue — but design for LED's true black and treat projection as the degraded-but-cheaper case. (General display-tech background: [LED display](https://en.wikipedia.org/wiki/LED_display), [contrast ratio](https://en.wikipedia.org/wiki/Contrast_ratio).)

---

## 4. Audio fundamentals — what each feature should drive

Makinect's audio brain is already production-grade (8-band log FFT, spectral-flux onset, YIN pitch, chromagram chord, autocorrelation BPM, Krumhansl-Schmuckler key, BS.1770 LUFS — all in [`Makinect/Visualizations/AudioEngine.swift`](../../Makinect/Visualizations/AudioEngine.swift)). The question isn't *can we extract these*; it's *what should each one control*. Three distinctions matter.

### BPM vs onset vs beat — the three timescales
These are constantly confused, and conflating them is *the* reason most reactive engines look mushy.

- **BPM (tempo):** the steady grid, beats per minute, derived by autocorrelation over a window. Slow-moving, stable, *predictive* — you know where the next beat *should* land. Drives **periodic motion**: rotation rate, scan speed, the pulse of a tunnel. ([Tempo](https://en.wikipedia.org/wiki/Tempo).)
- **Onset:** a detected *attack* — a sudden rise in spectral energy, found via [spectral flux / onset detection](https://en.wikipedia.org/wiki/Onset_(audio)). Sub-frame fast, *reactive*, fires on the actual transient (kick, snare, pluck) whether or not it's on the grid. Drives **instantaneous events**: the flash, the cut, the explode-pop. Makinect already exposes this as a boolean — it is the sharp-transient path.
- **Beat:** a *musical* downbeat — usually the intersection of "the grid says now" *and* "an onset happened." Beats are a subset of onsets aligned to the BPM phase.

The perceptual sharpness in INZO comes from the **onset layer being tight and the BPM layer being smooth** — fire hard exactly on the hit, glide everything else. ML beat-trackers run ~100–200 ms latency, far too slow for transient sync ([TISMIR](https://transactions.ismir.net/articles/10.5334/tismir.189)); DSP spectral-flux onset is the sub-frame path, which is why Makinect's existing onset detector is the right tool and AI does not belong in the live loop (see [00-README](00-README.md), Proposal C).

### Spectral bands — and what each should drive
Split the spectrum and map each band to a *different visual role* so they don't all twitch in unison:

| Band | Rough range | What it should drive |
|---|---|---|
| **Sub** | ~20–60 Hz | The big slow stuff: overall scale, tunnel depth, the room-shaking "weight" of a drop. |
| **Bass** | ~60–250 Hz | Primary pulse — kick-driven scale pops, beam-count, the on-grid heartbeat. |
| **Mid** | ~250 Hz–4 kHz | The melodic/vocal body — hue, fan width, the "tune you follow." Best coupled to pitch/chord. |
| **High** | ~4–10 kHz+ | Detail and sparkle — fine particles, shimmer, edge highlights, hi-hat ticks. |

This separation is *why* a good show feels like it's "listening" — the bass moves the architecture while the highs move the glitter, independently. One band → one role.

### Song structure — and why STRUCTURE drives palette/pattern
A track is not a uniform stream; it has **sections**: intro → build → drop → breakdown → (build) → drop → outro. Each section has a job (tension, release, rest), and the strongest shows let the *section*, not the moment-to-moment audio, choose the **palette and the pattern family**. In INZO: intro = one violet fan, maximum void; first drop = beam-matrix tunnels + a red 6-beam section marker; breakdown = the cyan/violet "breath" split; rebuild = the rotating radial sunburst; finale = symmetric purple+green bursts. The audio *texture* changes within a section, but the *identity* (color + pattern) is set by the section. This is the **structural backbone** layer of the three-timescale sync model (see [01-video-analysis](01-video-analysis.md) for the full timestamped breakdown). ([Song structure](https://en.wikipedia.org/wiki/Song_structure).)

---

## 5. Color theory for light

Color on an emissive surface follows **additive** rules (Section 2), which is the opposite of the paint-mixing intuition most people carry.

- **Additive RGB.** Primaries are red, green, blue; they *sum* toward white, and absence is black. There is no "darken by adding" — to get darker you emit *less*. This is why a palette on LED is really a choice of *which hues to light up against a black void*, not pigments on a white page. ([Additive color](https://en.wikipedia.org/wiki/Additive_color).)
- **Complementary pairs.** Hues opposite on the color wheel (e.g. cyan ↔ red-orange, violet ↔ green-yellow) create maximum contrast and a sense of tension/resolution. INZO leans hard on this: the breakdown's **cyan-top / violet-bottom** split and the finale's **purple + green** are complementary-ish pairings chosen for separation, not harmony. Two complementary beams crossing also make the brightest, most legible additive node. ([Complementary colors](https://en.wikipedia.org/wiki/Complementary_colors).)
- **Palette-per-energy.** Map the *energy curve* to a palette: cool/sparse hues (deep violet, single cyan) for low-energy/intro/breakdown; hot/dense multicolor (green+blue+yellow) for drops. Energy goes up → palette warms and widens. This keeps color *meaningful* rather than random.
- **Color as section identity.** The most disciplined move in INZO: a color *names* a section. The red 6-beam accent isn't decoration — it's a punctuation mark that says "new section." When color changes only on structural boundaries (not on every beat), the audience subconsciously reads the song's form. Color is a low-frequency signal; spend it on structure (Section 4), not on the transient layer.

Makinect's universal color knobs (`hueShift`, `saturationMul` in `Makinect/Visualizations/VisualizationCommonParams.swift`) plus the `hsv2rgb`/`rgb2hsv` helpers in `Makinect/Visualizations/Shaders.metal` are the levers for all of this; the AI choreographer's job is to *schedule* them against song structure rather than slave them to instantaneous loudness.

---

## 6. Negative space — the core thesis

> **This is the most important section in the primer.** Everything above is necessary; this is the part that separates a world-class show from a screensaver.

Negative space is the **deliberate emptiness** — the black, the silence-of-the-eye — that surrounds and defines the lit geometry. In a laser show it is not "nothing happening." It is a *compositional element you place as carefully as the beams.* The frame `frames/t02-54_iris-close-negative-space.jpg` (the iris closing to a single point before a full blackout, ~2:54) is, paradoxically, one of the most *designed* moments in the whole 4:27.

Four principles:

1. **Restraint is the statement.** The INZO intro is a *single* violet beam-fan drifting in an otherwise black room for ~18 seconds (`frames/t00-01_intro-single-violet-fan.jpg`). With nothing competing for attention, that one beam carries enormous weight. The maximum-impact move is often *subtraction*. An engine that always fills the frame has thrown away its most powerful tool before the show starts.

2. **Blackouts are cues, not absence.** At ~2:50–2:57 the aperture irises down to a point and then the show goes to **full black** before the final section. That blackout is a *beat* — a held breath that makes the re-entry hit ten times harder. Silence and darkness are punctuation. A blackout placed on a structural boundary is one of the strongest transitions you have, and it costs zero render budget.

3. **Density follows energy — strictly.** The amount of stuff on screen should track the song's energy curve, and *only* the energy curve. Intro = one element. Build = density ramps with the rise. Drop = full matrix. Breakdown = pull *way* back (the cyan/violet "breath"). When density is monotonic with energy, the drop *feels* like a drop because the contrast against the preceding sparsity is real. If you were already at full density during the build, the drop has nowhere to go.

4. **An over-reactive engine kills the drop.** This is the failure mode to design against. If every kick, snare, hi-hat, and melodic note triggers a flash, the screen is *always* maxed out — there's no dynamic range left, no contrast, no negative space, and therefore no drop. Reacting to *everything* smears the three timescales (structural / rhythmic / transient) into uniform mush. The craft is **choosing what to ignore**: fire hard on the chosen transient, then *get out of the way* and let the black breathe until the next chosen moment.

The engineering consequence is direct and shapes the whole product. The AI choreographer's most valuable output isn't "where to put beams" — it's the **negative-space map**: *when to do almost nothing.* A deterministic engine that defaults to restraint and only escalates on scheduled structural cues (plus a thin live onset layer for micro-reactivity) will out-perform a maximally reactive one every time. This is the unfair advantage: most reactive software is built to *react more*; ours should be built to react *with discipline*. See [00-README](00-README.md) Proposal C/D and the three-timescale sync model in [01-video-analysis](01-video-analysis.md).

---

## 7. The vocabulary, in one breath

A great audio-reactive light show is **line-based geometry** (beams, fans, matrices, starbursts, spokes, polygons, Lissajous) rendered with **additive blending + bloom + HDR rolloff** so it reads as emitted light, displayed on a **true-black emissive surface** (LED wall ideal, dark-room projection acceptable), where **song structure** chooses the **palette and pattern family**, the **BPM grid** drives smooth periodic motion, **onsets** fire tight transient hits, and **negative space** is placed as deliberately as the light itself. Everything in this series builds on those terms.

---

## Sources

- Additive color — https://en.wikipedia.org/wiki/Additive_color
- Subtractive color — https://en.wikipedia.org/wiki/Subtractive_color
- Complementary colors — https://en.wikipedia.org/wiki/Complementary_colors
- Bloom (shader effect) — https://en.wikipedia.org/wiki/Bloom_(shader_effect)
- Academy Color Encoding System (ACES) — https://en.wikipedia.org/wiki/Academy_Color_Encoding_System
- Apple MetalFX — https://developer.apple.com/documentation/metalfx
- LED display — https://en.wikipedia.org/wiki/LED_display
- Contrast ratio — https://en.wikipedia.org/wiki/Contrast_ratio
- Onset (audio) — https://en.wikipedia.org/wiki/Onset_(audio)
- Tempo — https://en.wikipedia.org/wiki/Tempo
- Song structure — https://en.wikipedia.org/wiki/Song_structure
- ML beat-tracker latency (TISMIR) — https://transactions.ismir.net/articles/10.5334/tismir.189
- INZO – "Overthinker" (Unofficial 4K Laser Show), Vox Daemon — https://www.youtube.com/watch?v=UVaobBtZU2w
