# Critique — What You May Not Be Aware Of (the challenge)

Part of the docs/lightshow series — see [00-README](00-README.md). Read this against [03-landscape](03-landscape.md) (the verified terrain), [04-proposals](04-proposals.md) (the four options and the chosen Hybrid), and [06-roadmap](06-roadmap.md) (the sequencing this critique wants to bend).

> You asked to be challenged, not flattered. This document assumes the plan in [04-proposals](04-proposals.md) is *good* and attacks it anyway — because the cheapest place to find the load-bearing wrong assumption is here, in a docs PR, before a single engine line is written. Every section is: **the claim**, **why it's risky or wrong**, **what to do instead**. Nothing here relitigates the [resolved decisions](00-README.md) (LED/projection-only, docs-first, Hybrid = A+C). It pressure-tests how you *talk about* and *sequence* them.

---

## 1. "Festival-grade" is a marketing claim you cannot currently back

**The claim.** The goal (stated in the project brief) is "world-class, **festival-grade** audio-reactive light shows" with the fidelity of the INZO – "Overthinker" reference video.

**Why it's risky.** The reference is not a festival. We watched 80 frames: it is **two desk-unit RGB galvo projectors in a single haze-filled room** with a "Vox Daemon" eagle logo on the back wall. That is a *bedroom/studio laser demo* — gorgeous, but a 3-square-meter rig. "Festival-grade" implies a different universe: 50–150 m throw, redundant rigging, an LD running cues to SMPTE, audience-scanning safety variances, weatherproofing, and a touring tech rider. None of that is in the reference, and **none of it is what you're building** — you resolved to ship LED-wall/projection (screen/raster), not a touring laser system. Conflating "looks like that beautiful desk demo" with "festival-grade" sets a bar you'll be measured against and miss, and it quietly drags the roadmap toward problems (rigging, throw, audience safety) you explicitly scoped out.

There's a second trap: **festival main-stage visuals are overwhelmingly pre-rendered or timecoded media servers** (disguise, Resolume, Notch) — see [03-landscape](03-landscape.md). A festival LD is not looking for "more reactive"; they're looking for *show-control reliability*. "Festival-grade" therefore points your ambition at the one buyer least interested in your core differentiator.

**What to do instead.** Pick honest, defensible language and let it set scope:
- Replace "festival-grade" with **"the INZO 'Overthinker' aesthetic, rendered for LED/projection"** or **"club / mid-size-venue / installation-grade audio-reactive visuals."** Those are claims you can actually demo.
- Reserve "festival" for an explicit, dated roadmap aspiration (in [06-roadmap](06-roadmap.md)) gated on the show-control milestones (timecode, redundancy, output mapping at scale) — not the headline.
- Use the reference for what it actually teaches: **restraint and the three-timescale sync model** (structure / rhythm / transient), not scale. The sharpness in that video is compositional discipline, not wattage. That's reproducible on a screen. "Festival-scale" is not, and isn't the goal.

---

## 2. The pro market pre-programs to timecode — pure live-reactivity is a smaller niche than the plan assumes

**The claim.** The implicit thesis across the proposals is that *tighter, smarter live audio-reactivity* is the product wedge.

**Why it's risky.** Professional shows are **pre-programmed and locked to timecode (SMPTE/MTC) or Ableton Link** for two non-negotiable reasons: **repeatability** (the headliner's show must look identical in Berlin and São Paulo, and the LD must rehearse it) and **safety/liability** (a reactive system that does something unexpected on a kick during an audience-scanning cue is a lawsuit; even on screens, an epilepsy-risk strobe that fires on a false onset is a real problem). The verified landscape confirms the pro stack — BEYOND/QuickShow, disguise, Resolume — is built around timecode and cue lists, *not* live reaction. madmom's online beat-tracker runs ~100–200 ms latency ([ISMIR/TISMIR](https://transactions.ismir.net/articles/10.5334/tismir.189)), which is why pros don't trust live ML beat-following for tight sync and instead **lock to a known timeline**. So a product whose headline is "reacts live, better than anyone" is selling into the *smaller* slice of the market (improvisers, VJs, generative-art installations) while the *larger, better-funded* slice (touring/festival production) wants the opposite: determinism.

**Why this is actually good news for you.** Your real wedge is *not* "more reactive." It's **authoring speed + design quality** — getting from "here's a track" to "here's a tasteful, on-the-grid, gig-ready cue timeline" in minutes instead of the days an LD spends hand-programming. That is *exactly* what Proposal C (the AI choreographer) attacks, and it's why C is the genuinely defensible half of the Hybrid. The AI scorer produces a **timecode-locked, editable score** — which is what the pro market already wants — and then your DSP engine adds live micro-reactivity *on top* of the locked spine. You get repeatability *and* liveness, which neither the pure-live camp nor the pure-timecode camp offers.

**What to do instead.**
- **Reframe the headline from "live-reactive" to "AI-fast, timecode-ready authoring."** Live reactivity is a *feature* (the micro-layer), not the *pitch*.
- Make the **editable, timecode-anchored score the primary artifact** of the product — exportable, riderable, rehearsable. The brief already says C emits "an EDITABLE choreography score (cue timeline)"; foreground that it is *timecode-locked*, because that's the word the buyer searches for.
- Treat "fully autonomous live reaction with no pre-program" as a **demo mode and a creative-coding/installation niche**, not the enterprise sell.

---

## 3. The AI framing is half-right — be ruthless about *where* AI lives

**The claim.** "AI choreographer" is the radical, defensible idea (Proposal C, foregrounded in the Hybrid).

**Why it's half-wrong as commonly imagined.** The instinct most people have — and that a casual reader of "AI choreographer" will assume — is *AI driving the visuals live*. That is not viable, and the brief's own latency facts say so:
- **Generative/diffusion models in the render loop: no.** Nothing in a diffusion pipeline returns in <20 ms; you need sub-frame (16–33 ms at 60 Hz) for tight transients.
- **ML beat-trackers live: also no.** madmom online ≈ 100–200 ms ([TISMIR](https://transactions.ismir.net/articles/10.5334/tismir.189); [open-source beat-detection rundown](https://biff.ai/a-rundown-of-open-source-beat-detection-models/)). That's 6–12 frames of slop — the *opposite* of the "razor-sharp transient" you're chasing.
- **DSP spectral-flux onset: yes.** Makinect *already has it* (`Makinect/Visualizations/AudioEngine.swift`, ~1–2 frame latency). That is the only thing fast enough to fire on the kick. For real-time beat *phase* (not just onsets), [BTrack](https://github.com/adamstark/BTrack) is a real-time C++ option; ML trackers are for **offline** analysis where 200 ms doesn't matter.

So the correct architecture is the split the brief already names but is easy to lose in the word "choreographer": **AI is offline / near-real-time and never in the hot path.** Its job is (1) ingest the track + stems + structure + lyrics and emit the editable score, and (2) act as a **co-pilot** during authoring ("make the breakdown breathe more," "this drop is too busy — cut beam count 40%"). The deterministic <10 ms DSP/GPU engine *performs* the score; live spectral-flux onsets add the micro-reactivity.

**Why it still matters that you get the framing right.** If marketing or the roadmap drifts into "AI drives your show live," you will (a) overpromise something physically impossible at the latency you need, (b) invite the obvious "isn't this just another generative-visuals toy" dismissal, and (c) mis-sequence engineering toward a live-inference path that can't hit frame budget.

**What to do instead.**
- In every doc, state the rule once and hard: **"AI scores offline and assists authoring; DSP performs live. No model is ever in the <20 ms render loop."**
- Position the AI as a **choreographer + co-pilot**, explicitly *not* a live VJ. The novelty and defensibility are in the *score quality* and the *authoring acceleration*, not in live inference.
- Make sure [06-roadmap](06-roadmap.md) sequences the **DSP performer first** (it's mostly built) and the **offline scorer second**, so you ship a deterministic, demoable engine before you bet on the harder ML-quality problem.

---

## 4. A screen approximates a laser beam — it never replicates one. Set fidelity expectations honestly

**The claim.** Reproduce the INZO laser aesthetic as a "geometric visual vocabulary" on LED/projection.

**Why it's risky.** This is the right strategic call (no physical lasers — confirmed scope), but it carries a perception trap. The reason real galvo lasers look the way they do is **physics you cannot fully fake on an emissive raster display**:
- **Razor edge from persistence-of-vision.** A galvo draws points at ~30–65k pts/sec; the line is a *moving point*, so its edge is effectively infinitely thin and self-luminous. A screen line is a band of lit pixels — anti-aliased, finite-width, and it sits in front of a backlight or emits from an OLED, but it is *a filled shape*, not a drawn point.
- **Infinite black + true additive.** A laser beam in haze is *light added to literal darkness*; the "black" is the unlit room. An LCD has backlight bleed; even OLED/projection has ambient wash and a black floor far above zero. The dynamic range that makes laser beams feel like they're cutting space is **not reproducible** on most screens.
- **Volumetric haze interaction.** The beam you see *in the air* (not just where it lands) is Mie scattering through haze. On a screen you're faking the volumetric beam as a 2D gradient. Good fakery, but fakery.

If you market "looks like real lasers," anyone who has stood in a real laser show will clock the difference instantly, and you'll have set yourself up to lose a comparison you didn't need to enter.

**What to do instead.**
- **Say "laser-*inspired* geometric visuals," not "laser visuals."** Own the aesthetic, not the medium.
- **Lean into what screens beat lasers at:** saturated full-color fields (lasers are a few discrete wavelengths), high beam/element *density* (a screen can show 65k particles — `Makinect/Visualizations/ParametricSwarm` already does — where a galvo time-slices and dims), gradients, texture, image content, and arbitrary scale on a wall. Your competitive surface is *color + density + composition*, not edge sharpness.
- **Invest the rendering effort where it pays:** crisp additive blending, a tuned bloom (MetalFX is available — Apple SDK, ship-safe), disciplined negative space, and *tight transient timing*. The brief's own insight stands: the perceived sharpness is **the transient layer being tight and the negative space being disciplined**, not the literal edge. That you *can* nail on a screen.
- Calibrate the demo: show it on a **good projector in a dark room with haze**, the medium where the illusion holds — not a laptop panel in a lit office.

---

## 5. macOS/Metal is the single biggest strategic fork — decide it *before* the engine PRs

**The claim.** Build on the existing Swift+Metal codebase (Proposal A: reuses ~80% of Makinect).

**Why it's the highest-stakes risk in the whole plan.** ~80% reuse is real leverage and the right call for *your own shows* and for *speed to first demo*. But the verified landscape is blunt: **the professional live-visuals world is Windows-centric** (disguise, Resolume, Notch, MadMapper-on-Windows, BEYOND/QuickShow). NDI's strongest tooling, most media-server integrations, and the buyers' existing rigs are Windows. **A Mac-only product caps your addressable market to the slice of pros and prosumers on Apple hardware** — a real slice (a lot of VJs and creative coders are on Macs), but a fraction, and *not* the festival/touring buyer from §1. This is not a detail to discover after you've written three engine PRs against Metal-specific APIs (MetalFX upscaling, Metal compute kernels in `SyntheticFrameSource.swift`, the two-pass `MetalKinectView` pipeline). The deeper you build into Metal, the more expensive the eventual cross-platform decision becomes.

**The three honest options (pick one explicitly, now):**

| Option | What it means | Cost | Who it's for |
|---|---|---|---|
| **A. Stay Mac-native** | Keep Metal, accept the niche. Sell to Mac VJs / installation artists / your own shows. | Lowest now; market-capped forever. | If the product is *primarily for you* + a Mac prosumer niche. |
| **B. Port the renderer cross-platform** | Re-implement the geometry/raster layer on a portable GPU API (WebGPU/wgpu, Vulkan, or an abstraction). | Highest; throws away much of the ~80% reuse. | If you're committed to competing for the Windows pro market with the *renderer itself*. |
| **C. AI scorer as the cross-platform layer; thin native players** | The **AI choreographer + score format** is platform-agnostic (it's data + a service). Ship a *Mac* performer first; later, *thin players* on other platforms — or even export the score *into* Resolume/TD/disguise as cues. | Medium; preserves reuse *and* the wedge. | The Hybrid's natural shape: own the *score*, not every renderer. |

**What to do instead.** Option **C is the strategically coherent one** and it falls straight out of the Hybrid: your defensible IP is the **score** (the offline AI choreography + the editable timeline format), which has *no* platform dependency. The Mac+Metal engine becomes "the first and best player," not "the only product." That lets you:
- Ship fast on Mac (keep the ~80% reuse) **without** painting the *business* into a Mac corner.
- Later reach Windows pros by **exporting the score** into the tools they already run (interop, the demoted Proposal B's actual best use), or by writing thin players, rather than out-engineering Resolume on its home turf.
- **Decide this in [04-proposals](04-proposals.md) / [06-roadmap](06-roadmap.md) explicitly** — write down which of A/B/C you're choosing and why. Drifting into it by default = choosing A by accident.

---

## 6. Licensing landmines that will bite a *commercial* release specifically

**The claim.** Build on the open-source/interop stack surveyed in [03-landscape](03-landscape.md).

**Why it's risky.** "Open source" is not "free to ship in a paid product." Several pieces that are fine for prototyping are **not** clean for a commercial release, and the time to design around them is *before* they're load-bearing:

| Component | Reality for a paid product | Action |
|---|---|---|
| **Ableton Link** | Dual GPLv2+ / proprietary. A *closed* product must **license the proprietary terms from Ableton** ([license](https://github.com/Ableton/link/blob/master/LICENSE.md)). GPLv2 in a closed binary = viral, not an option. | Budget for the commercial Link license, or make tempo-sync pluggable so Link is optional. |
| **NDI SDK** | Free but **proprietary terms** (branding, redistribution constraints). Not "do whatever." | Read the NDI license before depending on it; consider **Syphon** (Simplified BSD — clean for commercial, macOS) as the primary path and NDI as opt-in. |
| **LYGIA shader library** | **Not MIT — Prosperity License.** Free non-commercial; **commercial needs a paid Patron license** ([LYGIA](https://github.com/patriciogonzalezvivo/lygia)). | Prototype with it if you must; **do not ship** LYGIA code without the Patron license. Prefer ISF + your own shaders. |
| **Shadertoy code** | Default **CC BY-NC-SA 3.0 — never shippable** commercially ([terms](https://www.shadertoy.com/terms)). | Reference/learn only. **Write your own** equivalents. |
| **ISF / ISF-for-Metal (VIDVOX)** | **Free for commercial + non-commercial**, Metal renderer open-sourced ([docs](https://docs.vidvox.net/opensource/)). | **This is your safe harbor.** Make ISF the primary shader-interop format. |

**What to do instead.**
- Adopt the project policy already stated and make it a hard gate: **techniques are free to learn from anywhere; only permissively/commercially-licensed *code* ships.** Build the dependency list around **ISF (free commercial) + own shaders + Syphon (BSD) + OSCKit (MIT) + Apple SDK (Accelerate/Metal/MetalFX)**.
- Treat **Ableton Link as a known paid line item**, not a freebie. If a Link license is undesirable, design the timecode/sync layer so Link is one pluggable backend among several (also reduces the lock-in).
- **Quarantine prototype-only deps** (LYGIA, any Shadertoy-derived shader) so they can't accidentally leak into a release build. A literal `prototype/` folder excluded from the shipping target is cheap insurance.

---

## 7. "Disrupting Resolume" head-on will fail — the defensible play is the *new combination*

**The claim (the temptation).** Build a better Resolume / compete on feature parity in the live-visuals space.

**Why it's wrong.** Resolume, disguise, Notch, and MadMapper are **entrenched, Windows-first, deeply integrated into existing rigs, and backed by years of LD muscle memory and plugin ecosystems** ([03-landscape](03-landscape.md)). Feature-parity is a multi-year, multi-engineer war you'd fight on their turf, on their OS (see §5), against their incumbency. You'd be the worse Resolume for a long time, and "worse and newer" loses. The brief's own strategic stance is correct and worth holding the line on: **build something new / unfair advantage — explicitly NOT competing with Resolume head-on.**

**Where your unfair advantage actually is.** It's the *combination* nobody else ships together:
- **Body-tracking** (Kinect v2 depth + Apple Vision pose — `KinectManager.swift`, `PoseDetector.swift`). Resolume doesn't have a performer's *body* as a first-class input.
- **AI-scored choreography** (Proposal C) — automated, editable, timecode-locked cue generation. Resolume makes you hand-build cues.
- **Geometry-sharp sound-to-light** with the disciplined three-timescale sync model and the production-grade DSP audio brain already in `Makinect/Visualizations/AudioEngine.swift` (8-band FFT, onset, YIN pitch, chroma chords, autocorrelation BPM, Krumhansl-Schmuckler key, BS.1770 LUFS).

No incumbent combines *body-tracked input + AI choreography + a tight DSP transient engine + geometric laser-aesthetic output.* That intersection is the moat.

**What to do instead.**
- **Position against the *job*, not the *tool*:** "from track to tasteful, gig-ready cue timeline in minutes." Don't say "Resolume alternative"; say "the thing that does the part Resolume makes you do by hand."
- **Interop, don't replace.** Lean into the demoted Proposal B as an *escape hatch*: export your AI score / your visuals (OSC/NDI/Syphon) *into* Resolume/TD/disguise. Plugging into the incumbent's rig is a *faster* path to pro users than displacing it — and it sidesteps the Windows problem from §5.
- **Make body-tracking a headline, not a footnote.** It's the single capability the incumbents structurally lack and the one that ties back to your own shows.

---

## How I could be wrong / what to validate first

This whole plan rests on a few assumptions that are *cheap to test now* and *expensive to discover after the engine PRs*. Ranked by how much they'd hurt if false:

1. **Does the AI score actually beat hand-programming?** — *The load-bearing bet of the entire Hybrid.* If a human LD's hand-built cue list looks meaningfully better than what the AI scorer produces, Proposal C collapses into "a nice starting template," not a product.
   **Cheap test:** Take 3 tracks (incl. INZO "Overthinker"). Have a skilled person hand-author a cue timeline; separately, hand-author the *kind* of score your AI is meant to emit (color arcs, energy curve, negative-space map, pattern selection on the BPM grid) — i.e. *simulate the AI's output by hand*. Blind-compare. If the simulated-AI score isn't clearly competitive, the ML quality bar is higher than the plan assumes. **Do this before building the scorer.**

2. **Do your target users want autonomy or control?** — The plan assumes people want the AI to do the work. VJs and LDs are often control freaks who distrust automation; "it chose for me" can be a *negative*. If they want a co-pilot, not an autopilot, the UX and pitch change.
   **Cheap test:** Show 5–10 VJs/LDs two mockups — "AI generates the whole show, you tweak" vs. "you drive, AI suggests." Watch which one they reach for and what they *fear*. (Pairs with §2: control-seeking buyers reinforce the timecode/editable-score framing.)

3. **Does the screen actually sell the laser aesthetic?** (§4) — If a screen render in a real venue reads as "nice visuals" but not "wow, lasers," the core aesthetic promise is softer than hoped.
   **Cheap test:** Build *one* scene — a single violet beam-fan + starburst, with tuned additive/bloom and disciplined negative space — and project it in a dark, hazed room. No engine, no AI. Just: does it land? This is a weekend, not a quarter.

4. **Is the Mac market big enough — or do you need cross-platform sooner than planned?** (§5) — If early interest is overwhelmingly Windows pros, Option C's "score-as-the-product" needs to come *forward* in the roadmap.
   **Cheap test:** Before committing engine sequencing, ask 10 prospective buyers what they run. If it's 8/10 Windows, let that reorder [06-roadmap](06-roadmap.md) toward the platform-agnostic score.

5. **Can the latency budget actually be hit end-to-end?** — The brief claims ~1–2 frame DSP latency, but that's *audio analysis*, not *audio → on-screen photons*. Add render, compositing, NDI/Syphon hops, projector/display lag, and the *felt* transient sync may be looser than the spec.
   **Cheap test:** Instrument a clap-to-flash measurement on the *existing* Makinect with a high-FPS phone camera. Measure real end-to-end latency *today*. If it's already 80 ms, "razor-sharp transients" needs a latency-reduction work item, not an assumption. (The brief even flags "audio→output latency metering" as missing — build that meter first.)

If 1 or 2 comes back negative, the *product* thesis needs rework before any engine PR. If 3, 4, or 5 comes back negative, the *roadmap sequencing* needs rework. All five are days-not-quarters experiments. Run them before [06-roadmap](06-roadmap.md) hardens.

---

## Sources

- INZO – "Overthinker" (Unofficial 4K Laser Show), Vox Daemon — reference video: https://www.youtube.com/watch?v=UVaobBtZU2w
- Online beat-tracking latency (madmom / real-time trackers), ISMIR/TISMIR: https://transactions.ismir.net/articles/10.5334/tismir.189
- Rundown of open-source beat-detection models (latency comparison): https://biff.ai/a-rundown-of-open-source-beat-detection-models/
- BTrack (real-time C++ beat tracker): https://github.com/adamstark/BTrack
- Ableton Link (dual GPLv2+ / proprietary) — repo: https://github.com/Ableton/link ; license: https://github.com/Ableton/link/blob/master/LICENSE.md
- ISF (Interactive Shader Format), VIDVOX — open-source / commercial-free: https://isf.video/ ; open-source docs: https://docs.vidvox.net/opensource/ ; ISF for Metal: https://vdmx.vidvox.net/blog/isf-for-metal
- LYGIA shader library (Prosperity License — paid for commercial): https://github.com/patriciogonzalezvivo/lygia ; https://lygia.xyz
- Shadertoy terms (CC BY-NC-SA 3.0 default — not shippable commercially): https://www.shadertoy.com/terms
- Syphon Framework (Simplified BSD): https://github.com/Syphon/Syphon-Framework
- DMX over Art-Net / sACN / KiNET; OLA (Open Lighting Architecture): https://www.openlighting.org/ola/ ; TouchDesigner DMX Out CHOP: https://docs.derivative.ca/DMX_Out_CHOP
- Pangolin BEYOND/QuickShow 5.5 (timecode / Ableton Link / FB4 streaming — pro laser-control reference): https://pangolin.com/blogs/news/beyond-and-quickshow-5-5-release
- FDA/CDRH laser light show regulation (scope footnote): https://www.fda.gov/radiation-emitting-products/home-business-and-entertainment-products/laser-light-shows
- Audience scanning (safety, scope footnote): https://en.wikipedia.org/wiki/Audience_scanning
- Makinect codebase: `Makinect/Visualizations/AudioEngine.swift`, `Makinect/Visualizations/SyntheticFrameSource.swift`, `Makinect/Visualizations/MetalKinectView.swift`, `Makinect/Visualizations/ParametricSwarmConfig.swift`, `KinectManager.swift`, `PoseDetector.swift`
