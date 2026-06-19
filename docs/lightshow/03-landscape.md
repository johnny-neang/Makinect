# Technology Landscape — The Tools We Are Measuring Against

Part of the docs/lightshow series — see [00-README](00-README.md). Related: [04-proposals](04-proposals.md), [05-critique](05-critique.md), [02-domain-primer](02-domain-primer.md).

> **TL;DR.** The live-visual / media-server world is mature, Windows-centric, and owned by a handful of incumbents (Resolume, TouchDesigner, Notch, MadMapper, disguise). They have what we lack today: **output** (NDI/Syphon/DMX), **show-control** (timeline, cue, Link/timecode), and **mapping** (projection/output warping). We have what most of them treat as an afterthought: a **production-grade real-time audio brain** (`Makinect/Visualizations/AudioEngine.swift`) and **38 shipping Metal visualizers**. This doc is an honest, cited map of that terrain and where Makinect actually fits. The short version of our strategy: **we are not out-featuring Resolume.** We are building a narrower, sharper thing — see [04-proposals](04-proposals.md) and the honest reckoning in [05-critique](05-critique.md).

---

## How to read this doc

The temptation, when surveying a field of well-funded incumbents, is either to despair (they've done everything) or to delude (we'll do all of it, better). Both are wrong. The useful posture is **triangulation**: understand precisely what each tool is *for*, where it is *weak*, and which of its weaknesses maps to a place we already have an unfair advantage. That advantage is not "more features." It is the audio engine, the body-tracking inputs (Kinect v2 + Apple Vision — `KinectManager.swift`, `PoseDetector.swift`), and a from-scratch Metal codebase we fully own and can ship commercially without licensing landmines (see [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md) for the legal gating).

This survey covers eight tools. The comparison table is the spine; the prose afterward goes deep on the four that actually matter to our decision (Resolume, TouchDesigner, Notch, MadMapper). The rest are context.

---

## The comparison table

A few definitions so the columns mean something precise:

- **Audio-reactivity** = does the tool *natively* extract musical features (FFT bands, onsets, BPM, pitch/key) and bind them to parameters, or do you have to bolt that on? This is the column where Makinect is strongest and most of the field is weakest.
- **Output** = how pixels and control leave the box: video over network/inter-app (**NDI**, **Syphon**) and lighting control (**DMX over Art-Net / sACN (E1.31) / KiNET**).
- **Latency posture** = the tool's stance on audio-/timecode-to-photon latency. "Frame-locked" means it's gated by the 60 Hz render clock; "sample-accurate via timecode/Link" means it can be driven tighter than a frame by external sync.

| Tool | What it is | Core strength | Weakness | License / price (2026) | OS | Audio-reactivity | Output (DMX / NDI / Syphon) | Extensibility / SDK | Latency posture |
|---|---|---|---|---|---|---|---|---|---|
| **Resolume Arena / Avenue** | VJ / clip-based live video performance + projection mapping (Arena adds mapping + DMX) | Fastest path to a live show; huge clip-deck workflow; rock-solid live stability | Clip/layer paradigm, not generative; weak native audio analysis; mapping is good-not-great | Perpetual w/ 1yr updates: **Arena ≈ €799 / $899**, **Avenue ≈ €299 / $349** ([resolume.com](https://resolume.com/software/avenue-arena)) | Win + macOS | Basic FFT/BPM → param links; no onset/pitch/key | DMX (Arena, Art-Net/via fixtures) · NDI in/out · Syphon (mac) | FFGL plugins, OSC, DMX in/out | Frame-locked; OSC/MIDI/Link clock in |
| **TouchDesigner** | Node-based real-time visual programming / media environment | Infinitely flexible; the pro's Swiss-army knife; speaks every protocol | Steep curve; you build everything; per-machine commercial licensing | Non-commercial free; **Pro ≈ $600/yr or $2200 perpetual-ish**; Commercial tiers above ([derivative.ca](https://derivative.ca/product)) | Win (full) + macOS (reduced) | Audio CHOPs (FFT/analysis); BYO beat detection | DMX Out CHOP (Art-Net/sACN/KiNET) · NDI · Syphon | Python, GLSL, C++ CPlusPlus, DATs | Frame-locked; tight via timecode/Link/CHOP |
| **Notch** | Real-time GPU motion-graphics + effects authoring; runs inside media servers | Highest-end *generative* real-time visuals; particle/sim quality | Windows-only; DirectX engine; subscription; locked to its render ecosystem | **Subscription**: Builder Base ≈ £99/mo, RFX tiers above ([notch.one/pricing](https://www.notch.one/pricing)) | **Windows only** | FFT/audio modifiers; not a musical-feature engine | Via host (disguise/Notch LC) · NDI · Spout (not Syphon) | Notch blocks, scripting; closed engine | Frame-locked; timecode via host |
| **MadMapper** | Projection mapping + pixel/LED mapping + Syphon/NDI compositor | Best-in-class *mapping* UX on macOS; LED/DMX pixel mapping | Not a generative engine; a mapper, not a show brain | Perpetual ≈ **€399** ([madmapper.com](https://madmapper.com/buy)) | Win + macOS | Audio-reactive material params (basic) | DMX/Art-Net/sACN pixel-map · NDI · Syphon | ISF/GLSL materials, OSC | Frame-locked |
| **disguise (d3)** | Enterprise show-control + media-server hardware/software stack | Industry standard for tier-1 tours/broadcast; timecode + 3D stage sim | $$$$$; hardware-coupled; massive overkill for our scope | Hardware + software, quote-based (tens of $k+) ([disguise.one](https://www.disguise.one/)) | Win (on disguise HW) | Minimal; expects external content | Full pro lighting/video I/O · NDI | Notch host, plugins, API | **Sample-accurate via SMPTE timecode** |
| **vvvv gamma** | .NET-based visual + textual hybrid dataflow programming | Very powerful general-purpose creative-coding; great for installations | Niche; Windows; smaller ecosystem than TD | Free non-commercial; commercial license tiers ([visualprogramming.net](https://visualprogramming.net/)) | **Windows** | DSP nodes; BYO analysis | DMX/Art-Net · NDI · Spout | C# / .NET, nodes | Frame-locked |
| **Max/MSP + Jitter** | Audio-first visual programming (Cycling '74) | Unmatched *audio* DSP heritage; Jitter for visuals | Jitter visuals lag dedicated GPU engines; CPU-bound legacy | Perpetual ≈ **$399** or subscription ([cycling74.com](https://cycling74.com/shop)) | Win + macOS | **Excellent** (audio is its native domain) | Via externals; Syphon/NDI externals | JS, Java, C externals, gen~ | Frame-locked; tight audio path |
| **VDMX** | macOS-native modular VJ app (VIDVOX) | Deeply modular; **ISF** shader-native; very macOS-idiomatic | macOS-only; smaller user base; VJ-paradigm | Perpetual ≈ **$349** ([vidvox.net](https://vidvox.net/)) | **macOS only** | Audio analysis plugins; ISF audio | DMX/Art-Net · NDI · Syphon | **ISF shaders**, OSC, plugins | Frame-locked |

> Prices and OS support move; the perpetual-vs-subscription *shape* is the durable signal. Confirm before quoting in a sales context. The two facts I re-verified live for this doc: Resolume's perpetual-with-update-year model and pricing ([resolume.com](https://resolume.com/software/avenue-arena)), and Notch's move to subscription, Windows-only, DirectX-based rendering ([notch.one/pricing](https://www.notch.one/pricing), [manual.notch.one](https://manual.notch.one/2026.1/en/docs/reference/faq/subscriptions/)).

---

## The four that matter

### Resolume (Arena / Avenue) — the default we are *not* fighting

Resolume is the gravitational center of the VJ world. If a club, a mid-size festival stage, or a touring act needs "video, now, reliably," it is Resolume. Arena adds projection mapping (its "Advanced Output") and DMX, while Avenue is the cheaper performance-only sibling ([resolume.com](https://resolume.com/software/avenue-arena)).

**Pros.** The clip-deck workflow is the fastest live paradigm ever built — trigger, layer, blend, mask, go. It is cross-platform (Win + macOS), genuinely stable under show conditions, and has a deep ecosystem of clip packs and FFGL plugins. It speaks OSC, MIDI, NDI, Syphon, and (Arena) DMX.

**Cons.** It is a *playback and compositing* tool, not a *generative* one. Its native audio-reactivity is thin: an FFT-driven audio analysis you can link to parameters and a BPM clock, but **no spectral-flux onset detection, no YIN pitch, no chromagram chord, no Krumhansl-Schmuckler key** — the exact battery Makinect already runs in `Makinect/Visualizations/AudioEngine.swift`. To get the INZO-grade *transient* sharpness described in [01-video-analysis](01-video-analysis.md), a Resolume operator hand-triggers on the hits. We compute the hit.

**The honest read.** We will not out-feature Resolume on breadth, stability, or workflow polish — it has a decade-plus head start and a team. Saying otherwise would be the kind of delusion [05-critique](05-critique.md) exists to kill. Resolume is the *benchmark for live reliability* we must clear, not the *product* we are cloning. Our wedge is generative + audio-native + body-tracked, not "another clip deck."

### TouchDesigner — the escape hatch, demoted on purpose

TouchDesigner (TD) is the most powerful general-purpose tool in this list and the one a serious technical artist reaches for when nothing off-the-shelf fits. It is node-based dataflow over a GPU pipeline, with Python, GLSL, and C++ extensibility, and it speaks every protocol that matters — including DMX Out over Art-Net, sACN, and KiNET via the DMX Out CHOP ([docs.derivative.ca](https://docs.derivative.ca/DMX_Out_CHOP)).

**Pros.** Limitless. If you can describe a signal flow, you can build it. Audio CHOPs give you FFT and analysis; OSC/NDI/Syphon I/O is first-class; and it is the de-facto host for Notch blocks. For *interop*, it is unbeatable.

**Cons.** You build *everything* yourself — TD is a toolkit, not a finished instrument. The learning curve is famously steep. The macOS build is reduced relative to Windows. And the commercial licensing is **per-machine and recurring** ([derivative.ca](https://derivative.ca/product)), which is fine for a studio and corrosive for a *product you intend to sell*: you would either embed someone else's licensed runtime (you can't) or ask every customer to buy TD (you won't).

**The honest read.** This is exactly why TD is **demoted to an interop / escape-hatch** in our strategy, not the foundation. Makinect can emit OSC feature streams and NDI video *into* TD for the rare power user who wants to finish in TD — that's a feature, not a dependency. Building *on* TD would mean we don't own the IP, can't control the latency budget end-to-end, and inherit Windows-centric, per-seat economics. See proposal **B** in [04-proposals](04-proposals.md) for why it's the documented fallback rather than the plan.

### Notch — the generative ceiling, behind a Windows wall

Notch is the high-water mark for *real-time generative* visuals in live production — the particle systems, fields, and GPU sims behind a great many arena-scale shows. It runs as an authoring tool (Builder) and as blocks inside host media servers (disguise, Notch LC).

**Pros.** The generative/effects quality is genuinely top-tier, and the real-time authoring loop is excellent. If your bar is "broadcast-grade particle spectacle," Notch clears it.

**Cons.** It is **Windows-only**, built on a proprietary **DirectX** engine ([manual.notch.one](https://manual.notch.one/2026.1/en/docs/reference/faq/subscriptions/)), and has moved to a **subscription** model ([notch.one/pricing](https://www.notch.one/pricing)). Its audio support is FFT/modifier-level — reactive, but not a *musical-feature* engine. And as a closed engine locked to its host ecosystem, you don't extend it so much as configure it. Output to lighting is via the host, and inter-app video is Spout (Windows), not Syphon.

**The honest read.** Notch defines the *visual ceiling* we are implicitly compared to, and we should be clear-eyed: matching arena-grade particle spectacle is a multi-year quality climb. But two structural facts cut our way. First, the **laser aesthetic we're chasing is geometrically simpler** than Notch's fluid/particle showcases — beams, fans, tunnels, polygons in disciplined negative space ([02-domain-primer](02-domain-primer.md)) — and Makinect already ships harder-than-that work (raymarched `MandelbulbAviary`, `StableFluids`, 65k-particle `ParametricSwarm`). Second, Notch's **Windows/DirectX lock-in is a market we structurally cannot be locked out of**: a macOS-/Metal-native, audio-first tool isn't competing with Notch on its turf — it's a different turf.

### MadMapper — the mapping we'll have to earn

MadMapper is the macOS-favorite for **projection and LED/pixel mapping**. It is not a generative engine and doesn't pretend to be; it's where you take content (including via Syphon/NDI) and *put it precisely onto surfaces* — building façades, irregular screens, LED arrays — with DMX/Art-Net/sACN pixel mapping for fixtures ([madmapper.com](https://madmapper.com/)).

**Pros.** Best-in-class mapping UX on macOS, mature pixel-mapping, supports ISF/GLSL materials, and is perpetually licensed at a sane price.

**Cons.** It's a *mapper*, not a *show brain*. Audio-reactivity is limited to basic material parameters. It assumes the hard creative work happened upstream.

**The honest read.** MadMapper is the clearest statement of the **single biggest capability gap** between Makinect and a shippable light-show product: **output/projection mapping**. We have no warp, no multi-output, no pixel-map today. The good news is the problem is *well-understood and bounded* — it's engineering, not research — and on macOS we can stand on Syphon (Simplified BSD, commercial-safe) for the inter-app path while we build native mapping. Proposal **A** in [04-proposals](04-proposals.md) scopes this as a first-class workstream, not a someday.

---

## Sidebar — Real lasers are out of scope (and why)

It is worth being explicit, because the reference video (INZO — "Overthinker," analyzed in [01-video-analysis](01-video-analysis.md)) is *real RGB galvanometer lasers*, and the obvious question is "why not just drive real lasers?"

The tools exist and they are excellent. **Pangolin BEYOND / QuickShow 5.5** (Jan 2026) is the industry standard, now shipping Ableton Link, FB4 Turbo Streaming over UDP, and SMPTE timecode ([pangolin.com](https://pangolin.com/blogs/news/beyond-and-quickshow-5-5-release)). On the open-hardware side, the **Helios DAC** is an open-source USB→ILDA interface running ~65 kpps ([github.com/Grix/helios_dac](https://github.com/Grix/helios_dac)). Driving galvos is a solved problem with good tooling.

We are **deliberately out of scope** for physical lasers — not as a roadmap phase, but as a standing decision — for four concrete reasons:

1. **Regulatory.** In the US, laser light shows in commerce above Class IIIa (5 mW) require an **FDA/CDRH variance**; this is a real, ongoing compliance burden, not a checkbox ([fda.gov](https://www.fda.gov/radiation-emitting-products/home-business-and-entertainment-products/laser-light-shows)).
2. **Audience scanning** — pointing beams into a crowd — is **heavily restricted** and requires additional variance and engineering controls; getting it wrong is a safety and liability event, not a bug ([Wikipedia: Audience scanning](https://en.wikipedia.org/wiki/Audience_scanning)).
3. **Physical constraints.** Minimum beam heights above the audience (commonly ~3 m) and venue-by-venue safety sign-off make every show a custom physical-safety exercise.
4. **Hardware cost and logistics.** Real projectors, DACs, haze, and rigging are capital and operational overhead orthogonal to the software value we're building.

So we pursue the **geometric aesthetic on projection / LED instead**: beams, fans, tunnels, bursts, polygons, color choreography, and disciplined negative space, rendered crisply with additive blending and bloom. The look is the product; the photons are screen photons. (Physical galvo lasers / ILDA out remain a one-line *someday, not now* footnote — DMX fixture interop is the only physical-output direction we'd touch, and only as secondary/optional.)

---

## Where Makinect fits — and the gap, stated plainly

### What we already have (and most of the field treats as an afterthought)

- **A production-grade real-time audio brain.** `Makinect/Visualizations/AudioEngine.swift` runs an 8-band log FFT (~80 Hz–10 kHz), **spectral-flux onset** detection, **YIN pitch** (Hz + confidence), **chromagram chord**, **autocorrelation BPM** (60–200), **Krumhansl-Schmuckler key**, and BS.1770 LUFS — on the audio render thread, published to the UI with ~1–2 frames of latency. *No tool in the table above ships this depth of musical-feature extraction natively.* Resolume gives you FFT + BPM; TD gives you CHOPs and a build-it-yourself attitude; Notch gives you modifiers. We give you the music, decoded.
- **38 shipping Metal visualizers**, several harder than the laser look we want, including `HyperbolicTunnel`, `KineticWireframe`, `ParticleStorm`, `ParametricSwarm` (up to 65,536 GPU particles), `StableFluids`, and the raymarched `MandelbulbAviary`. The render framework — `Visualizer.swift`, `MetalKinectView.swift` (two-pass with `common_post_fs`), `Shaders.metal` (~4,770 lines), and six universal knobs in `VisualizationCommonParams.swift` — is real, owned, and Metal-native.
- **Unusual inputs.** Kinect v2 depth + Apple Vision pose (`KinectManager.swift`, `PoseDetector.swift`). *None* of the incumbents put body-tracking at the center. This is a genuine differentiator, not a checkbox.
- **The bones of show infra.** `MKAppState.swift` (tabs, scene arming, an 8-scene bar, tap-tempo, snapshots, panic), `MKPersistence.swift` (Codable JSON snapshots), and a *UI-only* MIDI mapping surface in `MKMidiOutputScreens.swift` that proves the patch/mapping UX pattern even though it has no CoreMIDI backend yet.

### What the incumbents have that we don't (yet)

| Capability | Incumbent state of the art | Makinect today | Gap class |
|---|---|---|---|
| **Network/inter-app video out** | NDI + Syphon everywhere | None | Engineering — Syphon is Simplified BSD, commercial-safe |
| **Vector/geometry render layer** | Native lines/shapes (Resolume, TD, MadMapper) | Raster shaders only; no SceneGraph of beams/lines/polygons | Engineering — the core of the laser look |
| **Projection / output mapping** | MadMapper, Resolume, disguise | None — no warp, no multi-output, no pixel-map | Engineering, well-bounded |
| **Timeline / cue + show-control** | disguise (SMPTE), all support Link/clock | Scene bar + tap-tempo only | Engineering + design |
| **Sync to external clock** | Ableton Link, SMPTE timecode | Internal tap-tempo only | Engineering (Link licensing — see [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md)) |
| **DMX / Art-Net / sACN out** | Universal (OLA, TD DMX Out CHOP) | None | Engineering — secondary/optional in our scope |
| **Ecosystem / plugins / clip packs** | Deep (Resolume, FFGL, ISF) | None | Time + community |
| **Audio→control latency metering** | Pro tools expose it | Not instrumented | Engineering |

The pattern in that "Gap class" column is the whole point: **almost every gap is bounded engineering, not open research.** Output, mapping, and show-control are problems the field solved years ago; we can stand on open, commercial-safe building blocks (Syphon, OLA/Art-Net, OSCKit, ISF-for-Metal) to close them — the licensing audit in [07-visual-and-tech-catalog](07-visual-and-tech-catalog.md) is what keeps us shippable. The one genuinely *novel* bet — an AI choreographer that scores a track offline into an editable cue timeline, performed live by a deterministic <10 ms DSP/GPU engine — is the subject of proposal **C** in [04-proposals](04-proposals.md), and it's novel precisely *because* the incumbents don't have it and the latency truth (below) makes the naive version impossible.

### The Windows-centricity reality (it cuts both ways)

The professional live-visual world is **Windows-centric**. Notch is Windows-only; vvvv is Windows; TouchDesigner's full build favors Windows; disguise runs on disguise's own Windows hardware. Inter-app video reflects this split: **Spout** (Windows) vs **Syphon** (macOS). This is a real headwind — the center of gravity, the plugin ecosystems, and the tier-1 touring infrastructure all assume Windows.

But it is also the **clearest seam in the market**. A **macOS-native, Metal-native, Apple-Silicon-class** audio-reactive engine with body-tracking is not fighting Notch or disguise for the same socket — it is a different machine for a different operator. Our latency story rides Accelerate/vDSP and MetalFX on hardware we control end-to-end, instead of inheriting someone else's runtime. We are not the Windows incumbents' competitor; we are the thing that doesn't exist on their platform.

### The latency truth that shapes everything

One landscape fact deserves its own line because it determines the *architecture*, not just the feature list: **ML beat-trackers run too slow for tight transient sync.** Online madmom-class models sit at ~100–200 ms latency ([TISMIR](https://transactions.ismir.net/articles/10.5334/tismir.189), [biff.ai survey](https://biff.ai/a-rundown-of-open-source-beat-detection-models/)) — fine for offline analysis, useless for firing on a kick. The sub-frame path is **DSP spectral-flux onset detection**, which Makinect *already has*, complemented by real-time C++ trackers like [BTrack](https://github.com/adamstark/BTrack) and, for sample-accuracy, **lookahead + Ableton Link / SMPTE timecode** — the same trick the pros use. The corollary: **generative/diffusion AI cannot live in the <20 ms render loop.** That's not a limitation to apologize for; it's the design constraint that makes the "AI scores offline, DSP performs live" split (proposal **C**) the *correct* use of AI rather than a buzzword — see [04-proposals](04-proposals.md).

---

## The bottom line

We are entering a mature field through its one open door. The incumbents own output, mapping, show-control, and ecosystem; we own a best-in-class audio brain, a real Metal codebase, body-tracking inputs, and a macOS platform nobody else is serving well. We do **not** win by becoming a worse Resolume or a Mac TouchDesigner. We win by being the narrow, sharp, audio-native, body-aware, AI-scored geometric light-show instrument that the table above does not contain a row for — and by being honest, as [05-critique](05-critique.md) insists, about every gap we still have to close.

---

## Sources

- Resolume — Avenue & Arena (software, pricing, mapping, DMX): https://resolume.com/software/avenue-arena
- Resolume — perpetual-with-update-year licensing model: https://resolume.com/blog/18695
- TouchDesigner — product / licensing: https://derivative.ca/product
- TouchDesigner — DMX Out CHOP (Art-Net / sACN / KiNET): https://docs.derivative.ca/DMX_Out_CHOP
- Notch — pricing / subscription: https://www.notch.one/pricing
- Notch — subscriptions, Windows/DirectX requirements (manual): https://manual.notch.one/2026.1/en/docs/reference/faq/subscriptions/
- MadMapper — projection / LED mapping: https://madmapper.com/
- disguise — show-control / media servers: https://www.disguise.one/
- vvvv gamma: https://visualprogramming.net/
- Cycling '74 — Max / MSP / Jitter: https://cycling74.com/shop
- VDMX (VIDVOX): https://vidvox.net/
- Open Lighting Architecture (OLA) — DMX/Art-Net/sACN open stack: https://www.openlighting.org/ola/
- Syphon Framework (Simplified BSD, macOS inter-app video): https://github.com/Syphon/Syphon-Framework
- ISF for Metal (VIDVOX, open shader interop): https://vdmx.vidvox.net/blog/isf-for-metal
- Pangolin BEYOND / QuickShow 5.5 (Link, FB4 Turbo, SMPTE): https://pangolin.com/blogs/news/beyond-and-quickshow-5-5-release
- Helios DAC (open-source USB→ILDA): https://github.com/Grix/helios_dac
- FDA/CDRH — laser light shows (variance requirements): https://www.fda.gov/radiation-emitting-products/home-business-and-entertainment-products/laser-light-shows
- Audience scanning (safety restrictions): https://en.wikipedia.org/wiki/Audience_scanning
- Online beat-tracking latency (TISMIR): https://transactions.ismir.net/articles/10.5334/tismir.189
- Open-source beat-detection survey (latency): https://biff.ai/a-rundown-of-open-source-beat-detection-models/
- BTrack (real-time C++ beat tracker): https://github.com/adamstark/BTrack
