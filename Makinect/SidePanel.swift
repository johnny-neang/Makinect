// SidePanel — Sidebar with connection controls, stream mode picker, and adjustable parameters

import SwiftUI

struct SidePanel: View {
    @Bindable var manager: KinectManager
    /// When true, render only the per-viz bespoke control sections.
    /// Used by the redesigned Library inspector, which has its own chrome
    /// for stream mode, depth, audio device, monitor, and resource panels.
    var compact: Bool = false

    private enum TopMode: String, CaseIterable, Identifiable {
        case stream = "Stream"
        case visualize = "Visualize"
        var id: String { rawValue }
    }
    @State private var topMode: TopMode = .stream

    var body: some View {
        if compact {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bespokeOnly
                }
                .padding()
            }
        } else {
            fullBody
        }
    }

    private var fullBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Source — pick where the visualization textures come from.
                // Defaults to .kinect; .synthetic frees the user from needing a device.
                Picker("Source", selection: $manager.source) {
                    ForEach(InputSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: manager.source) { _, new in
                    // Synthetic mode is visualize-only — Stream is a CPU pipeline that
                    // depends on real device frames.
                    if new == .synthetic {
                        topMode = .visualize
                        if manager.visualization == nil { manager.visualization = .pointCloud }
                    }
                }

                // Connection — only relevant in Kinect mode
                if manager.source == .kinect {
                    GroupBox("Connection") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(manager.isConnected ? .green : .red)
                                    .frame(width: 8, height: 8)
                                Text(manager.isConnected ? "Connected" : "Disconnected")
                            }

                            Button(manager.isConnected ? "Disconnect" : "Connect") {
                                if manager.isConnected {
                                    manager.disconnect()
                                } else {
                                    manager.connect()
                                }
                            }
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                // Top-level mode (Stream is hidden in synthetic since it requires a device)
                if manager.source == .kinect {
                    Picker("", selection: $topMode) {
                        ForEach(TopMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: topMode) { _, new in
                        if new == .stream { manager.visualization = nil }
                        else if manager.visualization == nil { manager.visualization = .pointCloud }
                    }
                }

                if manager.source == .kinect && topMode == .stream {
                    streamSection
                } else {
                    visualizationSection
                }

                // Device info
                if manager.isConnected {
                    GroupBox("Device Info") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let serial = manager.serialNumber {
                                LabeledContent("Serial", value: serial)
                            }
                            if let fw = manager.firmwareVersion, !fw.isEmpty {
                                LabeledContent("Firmware", value: fw)
                            }
                            LabeledContent("FPS", value: String(format: "%.1f", manager.currentFPS))
                            LabeledContent("Version", value: manager.activeVersion == .kinectV2 ? "Kinect v2" : "Kinect v1")
                        }
                        .font(.caption)
                    }
                }

                // Status
                Text(manager.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var streamSection: some View {
        GroupBox("Stream Mode") {
            Picker("Mode", selection: $manager.cameraMode) {
                ForEach(CameraMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }

        if manager.cameraMode == .rgb || manager.cameraMode == .skeleton {
            GroupBox("Pose Detection") {
                Toggle("Show Skeleton Overlay", isOn: $manager.showSkeleton)
            }
        }

        if manager.cameraMode == .segmented {
            GroupBox("Depth Segmentation") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Near Clip: \(Int(manager.segmentationNearMM)) mm")
                        .font(.callout)
                    Slider(value: $manager.segmentationNearMM, in: 0...4500, step: 50)

                    Text("Far Clip: \(Int(manager.segmentationFarMM)) mm")
                        .font(.callout)
                    Slider(value: $manager.segmentationFarMM, in: 0...4500, step: 50)
                }
            }
        }
    }

    @ViewBuilder
    private var visualizationSection: some View {
        GroupBox("Visualization") {
            Picker("Visualization", selection: Binding(
                get: { manager.visualization ?? .pointCloud },
                set: { manager.visualization = $0 }
            )) {
                ForEach(VisualizationKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }

        universalControlsSection

        GroupBox("Depth Range") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Near: \(Int(manager.segmentationNearMM)) mm").font(.callout)
                Slider(value: $manager.segmentationNearMM, in: 0...4500, step: 50)
                Text("Far: \(Int(manager.segmentationFarMM)) mm").font(.callout)
                Slider(value: $manager.segmentationFarMM, in: 0...4500, step: 50)
            }
        }

        GroupBox("Audio Input") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Source", selection: Binding(
                    get: { manager.audio.selectedInputID ?? 0 },
                    set: { manager.audio.switchInput(to: $0) }
                )) {
                    ForEach(manager.audio.availableInputs) { input in
                        Text(input.name + (input.isKinect ? "  (Kinect)" : ""))
                            .tag(input.id)
                    }
                }
                .labelsHidden()

                Button("Refresh") { manager.audio.refreshInputs() }
                    .controlSize(.small)

                LabeledContent("RMS", value: String(format: "%.3f", manager.audio.rms))
                    .font(.caption)
            }
        }

        // Phase B — full DSP audio monitor: waveform / FFT bars / spectrogram /
        // pitch / chord / key / BPM / RMS+peak+LUFS / onset LED.
        GroupBox("Audio Monitor") {
            AudioMonitorView(audio: manager.audio)
        }

        // System status — CPU / memory / FPS readouts so a VJ can see at a
        // glance whether they have headroom or are approaching frame drops.
        GroupBox("System") {
            ResourceMonitorView(monitor: manager.resourceMonitor)
        }

        bespokeOnly
    }

    /// Per-visualizer bespoke control sections (38 viz × Phase C).
    /// Extracted so the redesigned Library inspector can reuse just this
    /// block without dragging in the duplicated chrome above.
    @ViewBuilder
    private var bespokeOnly: some View {
        if manager.visualization == .pointCloud || manager.visualization == .voxelSculpt {
            GroupBox("Camera") {
                Text("Drag to orbit · Pinch / scroll to zoom")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if manager.visualization == .parametricSwarm { parametricSwarmSection }
        if manager.visualization == .particleStorm { particleStormSection }
        if manager.visualization == .mercuryStorm { mercuryStormSection }
        if manager.visualization == .mandelbulbAviary { mandelbulbAviarySection }
        if manager.visualization == .bodyOfPetals { bodyOfPetalsSection }
        if manager.visualization == .mocapConstellation { mocapConstellationSection }
        if manager.visualization == .sandMandala { sandMandalaSection }
        if manager.visualization == .strandVeil { strandVeilSection }
        if manager.visualization == .nebula { nebulaSection }
        if manager.visualization == .smokeGod { smokeGodSection }
        if manager.visualization == .volumetricAurora { volumetricAuroraSection }
        if manager.visualization == .plasmaSea { plasmaSeaSection }
        if manager.visualization == .vortexRingSmoke { vortexRingSmokeSection }
        if manager.visualization == .filamentCosmology { filamentCosmologySection }
        if manager.visualization == .stableFluids { stableFluidsSection }
        if manager.visualization == .dissipativeCells { dissipativeCellsSection }
        if manager.visualization == .opticalFlow { opticalFlowSection }
        if manager.visualization == .liquidLightCalligraphy { liquidLightCalligraphySection }
        if manager.visualization == .pixelStorm { pixelStormSection }
        if manager.visualization == .glitchMosaic { glitchMosaicSection }
        if manager.visualization == .impastoPainter { impastoPainterSection }
        if manager.visualization == .pointCloud { pointCloudSection }
        if manager.visualization == .voxelSculpt { voxelSculptSection }
        if manager.visualization == .kineticWireframe { kineticWireframeSection }
        if manager.visualization == .bodyPaint { bodyPaintSection }
        if manager.visualization == .cathedralOfBones { cathedralOfBonesSection }
        if manager.visualization == .hyperbolicTunnel { hyperbolicTunnelSection }
        if manager.visualization == .iridescentPlumage { iridescentPlumageSection }
        if manager.visualization == .origamiBody { origamiBodySection }
        if manager.visualization == .stainedCathedral { stainedCathedralSection }
        if manager.visualization == .glassOcean { glassOceanSection }
        if manager.visualization == .forestOfLight { forestOfLightSection }
        if manager.visualization == .spectralOcean { spectralOceanSection }
        if manager.visualization == .liquidChromeBody { liquidChromeBodySection }
        if manager.visualization == .velvetPetalField { velvetPetalFieldSection }
        if manager.visualization == .magneticIronFilings { magneticIronFilingsSection }
        if manager.visualization == .boidsMurmuration { boidsMurmurationSection }
        if manager.visualization == .memoryPalace { memoryPalaceSection }
    }

    @ViewBuilder
    private var magneticIronFilingsSection: some View {
        let cfg = manager.magneticIronFilings
        GroupBox("Magnetic Iron Filings") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Line Length", value: String(format: "%.2f", cfg.lineLength)).font(.caption)
                Slider(value: Bindable(cfg).lineLength, in: 0.3...3)
                LabeledContent("Field Strength", value: String(format: "%.2f", cfg.fieldStrength)).font(.caption)
                Slider(value: Bindable(cfg).fieldStrength, in: 0...3)
                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue)).font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)
                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling)).font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
                LabeledContent("Bass Hue", value: String(format: "%.2f", cfg.bassHueShift)).font(.caption)
                Slider(value: Bindable(cfg).bassHueShift, in: 0...1)
                Toggle(isOn: Bindable(cfg).onsetPolarityFlip) {
                    Text("Onset Flip Polarity").font(.caption)
                }
                LabeledContent("Onset Boost", value: String(format: "%.2f", cfg.onsetBoost)).font(.caption)
                Slider(value: Bindable(cfg).onsetBoost, in: 0...3)
                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation)).font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var boidsMurmurationSection: some View {
        let cfg = manager.boidsMurmuration
        GroupBox("Boids Murmuration") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Separation", value: String(format: "%.3f", cfg.separation)).font(.caption)
                Slider(value: Bindable(cfg).separation, in: 0...0.20)
                LabeledContent("Alignment", value: String(format: "%.3f", cfg.alignment)).font(.caption)
                Slider(value: Bindable(cfg).alignment, in: 0...0.20)
                LabeledContent("Cohesion", value: String(format: "%.3f", cfg.cohesion)).font(.caption)
                Slider(value: Bindable(cfg).cohesion, in: 0...0.10)
                LabeledContent("Predator", value: String(format: "%.3f", cfg.predator)).font(.caption)
                Slider(value: Bindable(cfg).predator, in: 0...0.50)
                LabeledContent("Bass Sep", value: String(format: "%.3f", cfg.bassSeparationBoost)).font(.caption)
                Slider(value: Bindable(cfg).bassSeparationBoost, in: 0...0.20)
                LabeledContent("Treble Coh", value: String(format: "%.3f", cfg.trebleCohesionBoost)).font(.caption)
                Slider(value: Bindable(cfg).trebleCohesionBoost, in: 0...0.10)
                LabeledContent("Onset Pred", value: String(format: "%.3f", cfg.onsetPredatorBoost)).font(.caption)
                Slider(value: Bindable(cfg).onsetPredatorBoost, in: 0...1)
                LabeledContent("Bird Size", value: String(format: "%.2f", cfg.birdSize)).font(.caption)
                Slider(value: Bindable(cfg).birdSize, in: 0.3...3)
                LabeledContent("Flap Rate", value: String(format: "%.2f", cfg.flapRate)).font(.caption)
                Slider(value: Bindable(cfg).flapRate, in: 0.1...3)
            }
        }
    }

    @ViewBuilder
    private var memoryPalaceSection: some View {
        let cfg = manager.memoryPalace
        GroupBox("Memory Palace") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Shuffle Rate", value: String(format: "%.2f", cfg.shuffleRate)).font(.caption)
                Slider(value: Bindable(cfg).shuffleRate, in: 0...3)
                LabeledContent("Gutter Width", value: String(format: "%.2f", cfg.gutterWidth)).font(.caption)
                Slider(value: Bindable(cfg).gutterWidth, in: 0.1...4)
                LabeledContent("Band Spread", value: String(format: "%.2f", cfg.bandSpread)).font(.caption)
                Slider(value: Bindable(cfg).bandSpread, in: 0...2)
                LabeledContent("Pane Bleed", value: String(format: "%.2f", cfg.paneBleed)).font(.caption)
                Slider(value: Bindable(cfg).paneBleed, in: 0...2)
                LabeledContent("Onset Flash", value: String(format: "%.2f", cfg.onsetFlash)).font(.caption)
                Slider(value: Bindable(cfg).onsetFlash, in: 0...2)
                LabeledContent("Hue Offset", value: String(format: "%+.2f", cfg.hueOffset)).font(.caption)
                Slider(value: Bindable(cfg).hueOffset, in: -1...1)
                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation)).font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)
                LabeledContent("Vignette", value: String(format: "%.2f", cfg.vignette)).font(.caption)
                Slider(value: Bindable(cfg).vignette, in: 0.5...3)
            }
        }
    }

    @ViewBuilder
    private var spectralOceanSection: some View {
        let cfg = manager.spectralOcean
        GroupBox("Spectral Ocean") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Ring Speed", value: String(format: "%.2f", cfg.ringSpeed)).font(.caption)
                Slider(value: Bindable(cfg).ringSpeed, in: 0...3)
                LabeledContent("Bass Speed", value: String(format: "%.2f", cfg.bassRingSpeed)).font(.caption)
                Slider(value: Bindable(cfg).bassRingSpeed, in: 0...3)
                LabeledContent("Density", value: String(format: "%.0f", cfg.ringDensity)).font(.caption)
                Slider(value: Bindable(cfg).ringDensity, in: 10...60)
                LabeledContent("Sharpness", value: String(format: "%.2f", cfg.crestSharpness)).font(.caption)
                Slider(value: Bindable(cfg).crestSharpness, in: 0.3...4)
                LabeledContent("Deep Hue", value: String(format: "%.2f", cfg.deepHue)).font(.caption)
                Slider(value: Bindable(cfg).deepHue, in: 0...1)
                LabeledContent("Warm Hue", value: String(format: "%.2f", cfg.warmHue)).font(.caption)
                Slider(value: Bindable(cfg).warmHue, in: 0...1)
                LabeledContent("Halo Hue", value: String(format: "%.2f", cfg.bodyHaloHue)).font(.caption)
                Slider(value: Bindable(cfg).bodyHaloHue, in: 0...1)
                LabeledContent("Onset Wave", value: String(format: "%.2f", cfg.onsetWave)).font(.caption)
                Slider(value: Bindable(cfg).onsetWave, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var liquidChromeBodySection: some View {
        let cfg = manager.liquidChromeBody
        GroupBox("Liquid Chrome") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Wobble", value: String(format: "%.2f", cfg.wobbleBase)).font(.caption)
                Slider(value: Bindable(cfg).wobbleBase, in: 0...2)
                LabeledContent("Bass Env", value: String(format: "%.2f", cfg.bassEnvBoost)).font(.caption)
                Slider(value: Bindable(cfg).bassEnvBoost, in: 0...3)
                LabeledContent("Treble Env", value: String(format: "%.2f", cfg.trebleEnvBoost)).font(.caption)
                Slider(value: Bindable(cfg).trebleEnvBoost, in: 0...3)
                LabeledContent("Fresnel", value: String(format: "%.2f", cfg.fresnelMix)).font(.caption)
                Slider(value: Bindable(cfg).fresnelMix, in: 0...1)
                LabeledContent("Onset Spike", value: String(format: "%.2f", cfg.onsetSpike)).font(.caption)
                Slider(value: Bindable(cfg).onsetSpike, in: 0...3)
                LabeledContent("Env Hue Shift", value: String(format: "%+.2f", cfg.envHueShift)).font(.caption)
                Slider(value: Bindable(cfg).envHueShift, in: -1...1)
                LabeledContent("Base Tone", value: String(format: "%+.2f", cfg.baseTone)).font(.caption)
                Slider(value: Bindable(cfg).baseTone, in: -0.5...0.5)
            }
        }
    }

    @ViewBuilder
    private var velvetPetalFieldSection: some View {
        let cfg = manager.velvetPetalField
        GroupBox("Velvet Petal Field") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Rings", value: "\(cfg.ringCount)").font(.caption)
                Slider(
                    value: Binding(get: { Double(cfg.ringCount) },
                                   set: { cfg.ringCount = Int($0) }),
                    in: 1...8, step: 1
                )
                LabeledContent("Divisions", value: "\(cfg.divisions)").font(.caption)
                Slider(
                    value: Binding(get: { Double(cfg.divisions) },
                                   set: { cfg.divisions = Int($0) }),
                    in: 4...30, step: 1
                )
                LabeledContent("Bass Bloom", value: String(format: "%.2f", cfg.bassBloom)).font(.caption)
                Slider(value: Bindable(cfg).bassBloom, in: 0...3)
                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue)).font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)
                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation)).font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1.5)
                LabeledContent("Petal Scale", value: String(format: "%.2f", cfg.petalScale)).font(.caption)
                Slider(value: Bindable(cfg).petalScale, in: 0.5...2)
                LabeledContent("Stem Sway", value: String(format: "%.2f", cfg.stemSway)).font(.caption)
                Slider(value: Bindable(cfg).stemSway, in: 0...3)
                LabeledContent("Onset Glow", value: String(format: "%.2f", cfg.onsetGlow)).font(.caption)
                Slider(value: Bindable(cfg).onsetGlow, in: 0...3)
            }
        }
    }

    @ViewBuilder
    private var stainedCathedralSection: some View {
        let cfg = manager.stainedCathedral
        GroupBox("Stained Cathedral") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Sectors", value: "\(cfg.sectorCount)").font(.caption)
                Slider(
                    value: Binding(get: { Double(cfg.sectorCount) },
                                   set: { cfg.sectorCount = Int($0) }),
                    in: 4...24, step: 1
                )
                LabeledContent("Rings", value: "\(cfg.ringCount)").font(.caption)
                Slider(
                    value: Binding(get: { Double(cfg.ringCount) },
                                   set: { cfg.ringCount = Int($0) }),
                    in: 3...16, step: 1
                )
                LabeledContent("Tracery W", value: String(format: "%.2f", cfg.traceryWidth)).font(.caption)
                Slider(value: Bindable(cfg).traceryWidth, in: 0.3...3)
                LabeledContent("Inner Glow", value: String(format: "%.2f", cfg.innerGlow)).font(.caption)
                Slider(value: Bindable(cfg).innerGlow, in: 0...3)
                LabeledContent("God Rays", value: String(format: "%.2f", cfg.godRayStrength)).font(.caption)
                Slider(value: Bindable(cfg).godRayStrength, in: 0...2)
                LabeledContent("Dust", value: String(format: "%.2f", cfg.dustIntensity)).font(.caption)
                Slider(value: Bindable(cfg).dustIntensity, in: 0...1)
                LabeledContent("Onset Flash", value: String(format: "%.2f", cfg.onsetFlash)).font(.caption)
                Slider(value: Bindable(cfg).onsetFlash, in: 0...2)
                LabeledContent("Halo Hue", value: String(format: "%.2f", cfg.bodyHaloHue)).font(.caption)
                Slider(value: Bindable(cfg).bodyHaloHue, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var glassOceanSection: some View {
        let cfg = manager.glassOcean
        GroupBox("Glass Ocean") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Refraction", value: String(format: "%.2f", cfg.refractionStrength)).font(.caption)
                Slider(value: Bindable(cfg).refractionStrength, in: 0...3)
                LabeledContent("Caustics", value: String(format: "%.2f", cfg.causticsIntensity)).font(.caption)
                Slider(value: Bindable(cfg).causticsIntensity, in: 0...3)
                LabeledContent("Coral Hue", value: String(format: "%.2f", cfg.coralHue)).font(.caption)
                Slider(value: Bindable(cfg).coralHue, in: 0...1)
                LabeledContent("Jellies", value: "\(cfg.jellyCount)").font(.caption)
                Slider(
                    value: Binding(get: { Double(cfg.jellyCount) },
                                   set: { cfg.jellyCount = Int($0) }),
                    in: 0...16, step: 1
                )
                LabeledContent("Jelly Size", value: String(format: "%.3f", cfg.jellySize)).font(.caption)
                Slider(value: Bindable(cfg).jellySize, in: 0.01...0.10)
                LabeledContent("Rim", value: String(format: "%.2f", cfg.rimStrength)).font(.caption)
                Slider(value: Bindable(cfg).rimStrength, in: 0...3)
                LabeledContent("Aberration", value: String(format: "%.2f", cfg.aberration)).font(.caption)
                Slider(value: Bindable(cfg).aberration, in: 0...3)
                LabeledContent("Onset Ripple", value: String(format: "%.2f", cfg.onsetRipple)).font(.caption)
                Slider(value: Bindable(cfg).onsetRipple, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var forestOfLightSection: some View {
        let cfg = manager.forestOfLight
        GroupBox("Forest of Light") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Spacing", value: String(format: "%.4f", cfg.pillarSpacing)).font(.caption)
                Slider(value: Bindable(cfg).pillarSpacing, in: 0.010...0.060)
                LabeledContent("Sway", value: String(format: "%.2f", cfg.swayAmount)).font(.caption)
                Slider(value: Bindable(cfg).swayAmount, in: 0...3)
                LabeledContent("Core Glow", value: String(format: "%.2f", cfg.coreGlow)).font(.caption)
                Slider(value: Bindable(cfg).coreGlow, in: 0...3)
                LabeledContent("Scatter", value: String(format: "%.2f", cfg.scatterAmount)).font(.caption)
                Slider(value: Bindable(cfg).scatterAmount, in: 0...3)
                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue)).font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)
                LabeledContent("Saturation", value: String(format: "%.2f", cfg.bandSaturation)).font(.caption)
                Slider(value: Bindable(cfg).bandSaturation, in: 0...2)
                LabeledContent("Onset Flash", value: String(format: "%.2f", cfg.onsetFlash)).font(.caption)
                Slider(value: Bindable(cfg).onsetFlash, in: 0...2)
                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling)).font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var hyperbolicTunnelSection: some View {
        let cfg = manager.hyperbolicTunnel
        GroupBox("Hyperbolic Tunnel") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Swirl Base", value: String(format: "%.2f", cfg.swirlBase)).font(.caption)
                Slider(value: Bindable(cfg).swirlBase, in: 0...0.5)
                LabeledContent("Bass Swirl", value: String(format: "%.2f", cfg.bassSwirl)).font(.caption)
                Slider(value: Bindable(cfg).bassSwirl, in: 0...1)
                LabeledContent("Fold Depth", value: "\(cfg.foldDepth)").font(.caption)
                Slider(
                    value: Binding(get: { Double(cfg.foldDepth) },
                                   set: { cfg.foldDepth = Int($0) }),
                    in: 1...12, step: 1
                )
                LabeledContent("Tile Sharpness", value: String(format: "%.1f", cfg.tileSharpness)).font(.caption)
                Slider(value: Bindable(cfg).tileSharpness, in: 1...12)
                LabeledContent("Radial Freq", value: String(format: "%.1f", cfg.radialFreq)).font(.caption)
                Slider(value: Bindable(cfg).radialFreq, in: 2...14)
                LabeledContent("Onset Glow", value: String(format: "%.2f", cfg.onsetGlow)).font(.caption)
                Slider(value: Bindable(cfg).onsetGlow, in: 0...2)
                LabeledContent("Vignette", value: String(format: "%.2f", cfg.vignetteScale)).font(.caption)
                Slider(value: Bindable(cfg).vignetteScale, in: 0.5...2)
                LabeledContent("Hue Offset", value: String(format: "%+.2f", cfg.hueOffset)).font(.caption)
                Slider(value: Bindable(cfg).hueOffset, in: -1...1)
            }
        }
    }

    @ViewBuilder
    private var iridescentPlumageSection: some View {
        let cfg = manager.iridescentPlumage
        GroupBox("Iridescent Plumage") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Feather Size", value: String(format: "%.4f", cfg.featherSize)).font(.caption)
                Slider(value: Bindable(cfg).featherSize, in: 0.005...0.05)
                LabeledContent("Bass Comb", value: String(format: "%.2f", cfg.bassGravityComb)).font(.caption)
                Slider(value: Bindable(cfg).bassGravityComb, in: 0...3)
                LabeledContent("Treble Ruffle", value: String(format: "%.2f", cfg.trebleRuffle)).font(.caption)
                Slider(value: Bindable(cfg).trebleRuffle, in: 0...3)
                LabeledContent("Hue Offset", value: String(format: "%+.2f", cfg.hueOffset)).font(.caption)
                Slider(value: Bindable(cfg).hueOffset, in: -0.5...0.5)
                LabeledContent("Highlight Hue", value: String(format: "%.2f", cfg.highlightHueOffset)).font(.caption)
                Slider(value: Bindable(cfg).highlightHueOffset, in: 0...1)
                LabeledContent("Gust", value: String(format: "%.2f", cfg.gustStrength)).font(.caption)
                Slider(value: Bindable(cfg).gustStrength, in: 0...3)
                LabeledContent("Sub-surface", value: String(format: "%.2f", cfg.subSurface)).font(.caption)
                Slider(value: Bindable(cfg).subSurface, in: 0...2)
                LabeledContent("Audio Glow", value: String(format: "%.2f", cfg.audioGlow)).font(.caption)
                Slider(value: Bindable(cfg).audioGlow, in: 0...2)
                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation)).font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1.5)
            }
        }
    }

    @ViewBuilder
    private var origamiBodySection: some View {
        let cfg = manager.origamiBody
        GroupBox("Origami Body") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Grid Size", value: String(format: "%.3f", cfg.gridSize)).font(.caption)
                Slider(value: Bindable(cfg).gridSize, in: 0.020...0.080)
                LabeledContent("Fold Speed", value: String(format: "%.2f", cfg.foldSpeed)).font(.caption)
                Slider(value: Bindable(cfg).foldSpeed, in: 0...3)
                LabeledContent("Onset Refold", value: String(format: "%.2f", cfg.onsetRefold)).font(.caption)
                Slider(value: Bindable(cfg).onsetRefold, in: 0...1)
                LabeledContent("Palette Bal", value: String(format: "%.2f", cfg.paletteBalance)).font(.caption)
                Slider(value: Bindable(cfg).paletteBalance, in: 0...1)
                LabeledContent("Paper Warmth", value: String(format: "%.2f", cfg.paperWarmth)).font(.caption)
                Slider(value: Bindable(cfg).paperWarmth, in: 0...1)
                LabeledContent("Ink Bleed", value: String(format: "%.2f", cfg.inkBleed)).font(.caption)
                Slider(value: Bindable(cfg).inkBleed, in: 0...2)
                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling)).font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
                LabeledContent("Brush Contrast", value: String(format: "%.2f", cfg.brushContrast)).font(.caption)
                Slider(value: Bindable(cfg).brushContrast, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var pointCloudSection: some View {
        let cfg = manager.pointCloud
        GroupBox("Point Cloud") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Point Size", value: String(format: "%.2f", cfg.pointSize)).font(.caption)
                Slider(value: Bindable(cfg).pointSize, in: 1...10)
                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue)).font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)
                LabeledContent("Hue Gradient", value: String(format: "%+.2f", cfg.hueGradient)).font(.caption)
                Slider(value: Bindable(cfg).hueGradient, in: -1...1)
                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation)).font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)
                LabeledContent("Bass Displace", value: String(format: "%.3f", cfg.bassDisplacement)).font(.caption)
                Slider(value: Bindable(cfg).bassDisplacement, in: 0...0.30)
            }
        }
    }

    @ViewBuilder
    private var voxelSculptSection: some View {
        let cfg = manager.voxelSculpt
        GroupBox("Voxel Sculpt") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Voxel Scale", value: String(format: "%.3f", cfg.voxelScale)).font(.caption)
                Slider(value: Bindable(cfg).voxelScale, in: 0.01...0.20)
                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue)).font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)
                LabeledContent("Hue Spread", value: String(format: "%.2f", cfg.hueSpread)).font(.caption)
                Slider(value: Bindable(cfg).hueSpread, in: 0...1)
                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation)).font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)
                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling)).font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var kineticWireframeSection: some View {
        let cfg = manager.kineticWireframe
        GroupBox("Kinetic Wireframe") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Line Thickness", value: String(format: "%.4f", cfg.lineThickness)).font(.caption)
                Slider(value: Bindable(cfg).lineThickness, in: 0.0005...0.0050)
                LabeledContent("Explosion", value: String(format: "%.2f", cfg.explosionMagnitude)).font(.caption)
                Slider(value: Bindable(cfg).explosionMagnitude, in: 0...0.6)
                LabeledContent("Base Hue", value: String(format: "%+.2f", cfg.baseHueShift)).font(.caption)
                Slider(value: Bindable(cfg).baseHueShift, in: -0.5...0.5)
                LabeledContent("Body Tint Hue", value: String(format: "%.2f", cfg.bodyTintHue)).font(.caption)
                Slider(value: Bindable(cfg).bodyTintHue, in: 0...1)
                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling)).font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var bodyPaintSection: some View {
        let cfg = manager.bodyPaint
        GroupBox("Body Paint") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Joint Size", value: String(format: "%.3f", cfg.jointSize)).font(.caption)
                Slider(value: Bindable(cfg).jointSize, in: 0.01...0.20)
                LabeledContent("Head Size", value: String(format: "%.3f", cfg.headSize)).font(.caption)
                Slider(value: Bindable(cfg).headSize, in: 0.02...0.30)
                LabeledContent("Beat Boost", value: String(format: "%.2f", cfg.beatBoost)).font(.caption)
                Slider(value: Bindable(cfg).beatBoost, in: 0...3)
                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling)).font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...8)
                LabeledContent("Hue Offset", value: String(format: "%+.2f", cfg.hueOffset)).font(.caption)
                Slider(value: Bindable(cfg).hueOffset, in: -0.5...0.5)
                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation)).font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)
                LabeledContent("Falloff", value: String(format: "%.2f", cfg.falloff)).font(.caption)
                Slider(value: Bindable(cfg).falloff, in: 0.3...3)
                LabeledContent("Trail", value: String(format: "%.2f", cfg.trail)).font(.caption)
                Slider(value: Bindable(cfg).trail, in: 0.1...3)
                LabeledContent("Smoothing", value: String(format: "%.2f", cfg.smoothing)).font(.caption)
                Slider(value: Bindable(cfg).smoothing, in: 0.05...1)
            }
        }
    }

    @ViewBuilder
    private var cathedralOfBonesSection: some View {
        let cfg = manager.cathedralOfBones
        GroupBox("Cathedral of Bones") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Heart Size", value: String(format: "%.3f", cfg.heartSize)).font(.caption)
                Slider(value: Bindable(cfg).heartSize, in: 0.005...0.080)
                LabeledContent("Heart Pulse", value: String(format: "%.2f", cfg.heartPulse)).font(.caption)
                Slider(value: Bindable(cfg).heartPulse, in: 0...3)
                LabeledContent("Nerve", value: String(format: "%.2f", cfg.nerveIntensity)).font(.caption)
                Slider(value: Bindable(cfg).nerveIntensity, in: 0...3)
                LabeledContent("Bone Tint", value: String(format: "%.2f", cfg.boneTint)).font(.caption)
                Slider(value: Bindable(cfg).boneTint, in: 0...1)
                LabeledContent("Strobe", value: String(format: "%.2f", cfg.strobeIntensity)).font(.caption)
                Slider(value: Bindable(cfg).strobeIntensity, in: 0...3)
                LabeledContent("Plate Warmth", value: String(format: "%.2f", cfg.plateWarmth)).font(.caption)
                Slider(value: Bindable(cfg).plateWarmth, in: 0...1)
                LabeledContent("Viscera Glow", value: String(format: "%.2f", cfg.visceraGlow)).font(.caption)
                Slider(value: Bindable(cfg).visceraGlow, in: 0...3)
                LabeledContent("Bone Thickness", value: String(format: "%.2f", cfg.boneThickness)).font(.caption)
                Slider(value: Bindable(cfg).boneThickness, in: 0.4...3)
            }
        }
    }

    @ViewBuilder
    private var pixelStormSection: some View {
        let cfg = manager.pixelStorm
        GroupBox("Pixel Storm") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Samples", value: "\(cfg.sampleCount)").font(.caption)
                Slider(
                    value: Binding(get: { Double(cfg.sampleCount) },
                                   set: { cfg.sampleCount = Int($0) }),
                    in: 4...16, step: 1
                )
                LabeledContent("Fall Speed", value: String(format: "%.2f", cfg.fallSpeed)).font(.caption)
                Slider(value: Bindable(cfg).fallSpeed, in: 0...3)
                LabeledContent("Threshold", value: String(format: "%+.2f", cfg.thresholdOffset)).font(.caption)
                Slider(value: Bindable(cfg).thresholdOffset, in: -0.3...0.3)
                LabeledContent("Body Protect", value: String(format: "%.2f", cfg.bodyProtect)).font(.caption)
                Slider(value: Bindable(cfg).bodyProtect, in: 0...1)
                LabeledContent("Hue Tint", value: String(format: "%.2f", cfg.hueTint)).font(.caption)
                Slider(value: Bindable(cfg).hueTint, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var glitchMosaicSection: some View {
        let cfg = manager.glitchMosaic
        GroupBox("Glitch Mosaic") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Tile Size", value: String(format: "%.3f", cfg.tileSize)).font(.caption)
                Slider(value: Bindable(cfg).tileSize, in: 0.005...0.060)
                LabeledContent("Bass Pump", value: String(format: "%.3f", cfg.bassPump)).font(.caption)
                Slider(value: Bindable(cfg).bassPump, in: 0...0.06)
                LabeledContent("Glitch Prob", value: String(format: "%.2f", cfg.glitchProbability)).font(.caption)
                Slider(value: Bindable(cfg).glitchProbability, in: 0.50...0.99)
                LabeledContent("RGB Sep", value: String(format: "%.4f", cfg.rgbSeparation)).font(.caption)
                Slider(value: Bindable(cfg).rgbSeparation, in: 0...0.020)
                LabeledContent("Rim", value: String(format: "%.2f", cfg.rimIntensity)).font(.caption)
                Slider(value: Bindable(cfg).rimIntensity, in: 0...1)
                LabeledContent("Onset Strobe", value: String(format: "%.2f", cfg.onsetStrobe)).font(.caption)
                Slider(value: Bindable(cfg).onsetStrobe, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var impastoPainterSection: some View {
        let cfg = manager.impastoPainter
        GroupBox("Impasto Painter") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Brush Freq", value: String(format: "%.0f", cfg.brushFreq)).font(.caption)
                Slider(value: Bindable(cfg).brushFreq, in: 60...320)
                LabeledContent("Bass Pump", value: String(format: "%.0f", cfg.bassPump)).font(.caption)
                Slider(value: Bindable(cfg).bassPump, in: 0...160)
                LabeledContent("Base Hue", value: String(format: "%+.2f", cfg.baseHueShift)).font(.caption)
                Slider(value: Bindable(cfg).baseHueShift, in: -0.5...0.5)
                LabeledContent("Highlight Hue", value: String(format: "%+.2f", cfg.highlightHueShift)).font(.caption)
                Slider(value: Bindable(cfg).highlightHueShift, in: -0.5...0.5)
                LabeledContent("BG Desat", value: String(format: "%.2f", cfg.bgDesaturation)).font(.caption)
                Slider(value: Bindable(cfg).bgDesaturation, in: 0...1)
                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling)).font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var stableFluidsSection: some View {
        let cfg = manager.stableFluids
        GroupBox("Stable Fluids — Sim") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Dissipation", value: String(format: "%.4f", cfg.dissipation))
                    .font(.caption)
                Slider(value: Bindable(cfg).dissipation, in: 0.95...0.999)

                LabeledContent("Viscosity", value: String(format: "%.5f", cfg.viscosity))
                    .font(.caption)
                Slider(value: Bindable(cfg).viscosity, in: 0...0.01)
            }
        }
        GroupBox("Stable Fluids — Color") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Hue A", value: String(format: "%.2f", cfg.hueA))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueA, in: 0...1)
                LabeledContent("Hue B", value: String(format: "%.2f", cfg.hueB))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueB, in: 0...1)
                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation))
                    .font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)
                LabeledContent("Value", value: String(format: "%.2f", cfg.value))
                    .font(.caption)
                Slider(value: Bindable(cfg).value, in: 0.3...1.5)
                LabeledContent("Auto-drift", value: String(format: "%.2f", cfg.autoHueDrift))
                    .font(.caption)
                Slider(value: Bindable(cfg).autoHueDrift, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var dissipativeCellsSection: some View {
        let cfg = manager.dissipativeCells
        GroupBox("Dissipative Cells") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Lifespan", value: "\(Int(cfg.cellLifespan))f")
                    .font(.caption)
                Slider(value: Bindable(cfg).cellLifespan, in: 200...1200)

                LabeledContent("Drift", value: String(format: "%.4f", cfg.driftStrength))
                    .font(.caption)
                Slider(value: Bindable(cfg).driftStrength, in: 0...0.003)

                LabeledContent("Damping", value: String(format: "%.3f", cfg.damping))
                    .font(.caption)
                Slider(value: Bindable(cfg).damping, in: 0.85...0.99)

                LabeledContent("Min Cells", value: "\(cfg.minCells)")
                    .font(.caption)
                Slider(
                    value: Binding(get: { Double(cfg.minCells) },
                                   set: { cfg.minCells = Int($0) }),
                    in: 6...32, step: 1
                )

                LabeledContent("Initial Radius", value: String(format: "%.3f", cfg.initialRadius))
                    .font(.caption)
                Slider(value: Bindable(cfg).initialRadius, in: 0.10...0.30)

                Toggle("Mitosis on Onset", isOn: Bindable(cfg).mitosisOnOnset)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var opticalFlowSection: some View {
        let cfg = manager.opticalFlow
        GroupBox("Optical-Flow Painter") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Viscosity", value: String(format: "%.3f", cfg.viscosity))
                    .font(.caption)
                Slider(value: Bindable(cfg).viscosity, in: 0.92...0.999)

                LabeledContent("Motion Gate", value: String(format: "%.4f", cfg.motionGate))
                    .font(.caption)
                Slider(value: Bindable(cfg).motionGate, in: 0...0.01)

                LabeledContent("Hue A", value: String(format: "%.2f", cfg.hueA))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueA, in: 0...1)

                LabeledContent("Hue B", value: String(format: "%.2f", cfg.hueB))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueB, in: 0...1)

                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation))
                    .font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)

                LabeledContent("Brightness", value: String(format: "%.2f", cfg.value))
                    .font(.caption)
                Slider(value: Bindable(cfg).value, in: 0...1)

                LabeledContent("Auto-drift", value: String(format: "%.2f", cfg.autoHueDrift))
                    .font(.caption)
                Slider(value: Bindable(cfg).autoHueDrift, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var liquidLightCalligraphySection: some View {
        let cfg = manager.liquidLightCalligraphy
        GroupBox("Liquid Light Calligraphy") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Trail Decay", value: String(format: "%.3f", cfg.trailDecay))
                    .font(.caption)
                Slider(value: Bindable(cfg).trailDecay, in: 0.90...0.999)

                LabeledContent("Viscosity", value: String(format: "%.4f", cfg.viscosity))
                    .font(.caption)
                Slider(value: Bindable(cfg).viscosity, in: 0...0.005)

                LabeledContent("Brush Size", value: String(format: "%.2f", cfg.brushRadius))
                    .font(.caption)
                Slider(value: Bindable(cfg).brushRadius, in: 0.3...3.0)

                Toggle("Per-joint Hues", isOn: Bindable(cfg).perJointHue)
                    .font(.callout)

                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var vortexRingSmokeSection: some View {
        let cfg = manager.vortexRingSmoke
        GroupBox("Vortex Ring Smoke") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Spawn Interval", value: String(format: "%.1fs", cfg.spawnInterval))
                    .font(.caption)
                Slider(value: Bindable(cfg).spawnInterval, in: 0.3...3.0)

                LabeledContent("Rise Speed", value: String(format: "%.4f", cfg.riseSpeed))
                    .font(.caption)
                Slider(value: Bindable(cfg).riseSpeed, in: 0...0.005)

                LabeledContent("Swirl Freq", value: String(format: "%.1f", cfg.swirlFreq))
                    .font(.caption)
                Slider(value: Bindable(cfg).swirlFreq, in: 4...16)

                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation))
                    .font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)

                LabeledContent("Body Boost", value: String(format: "%.2f", cfg.bodyBoost))
                    .font(.caption)
                Slider(value: Bindable(cfg).bodyBoost, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var filamentCosmologySection: some View {
        let cfg = manager.filamentCosmology
        GroupBox("Filament Cosmology") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("March Steps", value: "\(cfg.marchSteps)")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.marchSteps) },
                        set: { cfg.marchSteps = Int($0) }
                    ),
                    in: 12...72, step: 1
                )

                LabeledContent("Threshold", value: String(format: "%.2f", cfg.filamentThreshold))
                    .font(.caption)
                Slider(value: Bindable(cfg).filamentThreshold, in: 0.30...0.80)

                LabeledContent("Worley Scale", value: String(format: "%.2f", cfg.worleyScale))
                    .font(.caption)
                Slider(value: Bindable(cfg).worleyScale, in: 0.5...3.0)

                LabeledContent("Lens Strength", value: String(format: "%.2f", cfg.lensStrength))
                    .font(.caption)
                Slider(value: Bindable(cfg).lensStrength, in: 0...1)

                LabeledContent("Hue Shift", value: String(format: "%+.2f", cfg.hueShift))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueShift, in: -0.5...0.5)

                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling))
                    .font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...3)
            }
        }
    }

    @ViewBuilder
    private var plasmaSeaSection: some View {
        let cfg = manager.plasmaSea
        GroupBox("Plasma Sea — Waves") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Wave Scale", value: String(format: "%.1f", cfg.waveScale))
                    .font(.caption)
                Slider(value: Bindable(cfg).waveScale, in: 1...8)

                LabeledContent("Wave Speed", value: String(format: "%.2f", cfg.waveSpeed))
                    .font(.caption)
                Slider(value: Bindable(cfg).waveSpeed, in: 0...2)

                LabeledContent("Dispersion", value: String(format: "%.2f", cfg.dispersion))
                    .font(.caption)
                Slider(value: Bindable(cfg).dispersion, in: 0...2)

                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling))
                    .font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...3)
            }
        }

        GroupBox("Plasma Sea — Color") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Deep Hue", value: String(format: "%+.2f", cfg.deepHueShift))
                    .font(.caption)
                Slider(value: Bindable(cfg).deepHueShift, in: -0.5...0.5)

                LabeledContent("Lit Hue", value: String(format: "%+.2f", cfg.litHueShift))
                    .font(.caption)
                Slider(value: Bindable(cfg).litHueShift, in: -0.5...0.5)

                LabeledContent("Body Glow", value: String(format: "%.2f", cfg.bodyGlowHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).bodyGlowHue, in: 0...1)

                LabeledContent("Brightness", value: String(format: "%.2f", cfg.brightness))
                    .font(.caption)
                Slider(value: Bindable(cfg).brightness, in: 0.3...2)
            }
        }
    }

    @ViewBuilder
    private var volumetricAuroraSection: some View {
        let cfg = manager.volumetricAurora
        GroupBox("Aurora — Motion") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Fall Speed", value: String(format: "%.3f", cfg.fallSpeed))
                    .font(.caption)
                Slider(value: Bindable(cfg).fallSpeed, in: 0...0.30)

                LabeledContent("Curtain Freq", value: String(format: "%.1f", cfg.curtainFreq))
                    .font(.caption)
                Slider(value: Bindable(cfg).curtainFreq, in: 4...16)

                LabeledContent("Drop", value: String(format: "%.2f", cfg.dropMagnitude))
                    .font(.caption)
                Slider(value: Bindable(cfg).dropMagnitude, in: 0...1)

                LabeledContent("Stars", value: String(format: "%.2f", cfg.starDensity))
                    .font(.caption)
                Slider(value: Bindable(cfg).starDensity, in: 0...1)
            }
        }

        GroupBox("Aurora — Palette") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Hue A", value: String(format: "%.2f", cfg.hueA))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueA, in: 0...1)

                LabeledContent("Hue B", value: String(format: "%.2f", cfg.hueB))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueB, in: 0...1)

                LabeledContent("Hue C", value: String(format: "%.2f", cfg.hueC))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueC, in: 0...1)

                LabeledContent("Body Boost", value: String(format: "%.2f", cfg.bodyBoost))
                    .font(.caption)
                Slider(value: Bindable(cfg).bodyBoost, in: 0...3)

                LabeledContent("Shimmer", value: String(format: "%.2f", cfg.trebleShimmer))
                    .font(.caption)
                Slider(value: Bindable(cfg).trebleShimmer, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var smokeGodSection: some View {
        let cfg = manager.smokeGod
        GroupBox("Smoke God — March") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Steps", value: "\(cfg.marchSteps)")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.marchSteps) },
                        set: { cfg.marchSteps = Int($0) }
                    ),
                    in: 16...64, step: 1
                )

                LabeledContent("Threshold", value: String(format: "%.2f", cfg.densityThreshold))
                    .font(.caption)
                Slider(value: Bindable(cfg).densityThreshold, in: 0.20...0.60)

                LabeledContent("Density", value: String(format: "%.2f", cfg.densityScale))
                    .font(.caption)
                Slider(value: Bindable(cfg).densityScale, in: 0.3...2.5)

                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling))
                    .font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
            }
        }

        GroupBox("Smoke God — Two-tone Palette") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Lit Hue", value: String(format: "%.2f", cfg.litHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).litHue, in: 0...1)

                LabeledContent("Shadow Hue", value: String(format: "%.2f", cfg.shadowHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).shadowHue, in: 0...1)

                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation))
                    .font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)

                LabeledContent("Embers", value: String(format: "%.2f", cfg.emberStrength))
                    .font(.caption)
                Slider(value: Bindable(cfg).emberStrength, in: 0...3)
            }
        }
    }

    @ViewBuilder
    private var nebulaSection: some View {
        let cfg = manager.nebula
        GroupBox("Nebula — Quality") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("March Steps", value: "\(cfg.marchSteps)")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.marchSteps) },
                        set: { cfg.marchSteps = Int($0) }
                    ),
                    in: 16...64, step: 1
                )

                LabeledContent("Threshold", value: String(format: "%.2f", cfg.densityThreshold))
                    .font(.caption)
                Slider(value: Bindable(cfg).densityThreshold, in: 0.30...0.60)

                LabeledContent("Density", value: String(format: "%.2f", cfg.densityScale))
                    .font(.caption)
                Slider(value: Bindable(cfg).densityScale, in: 0.5...3.0)

                LabeledContent("Noise Scale", value: String(format: "%.2f", cfg.noiseScale))
                    .font(.caption)
                Slider(value: Bindable(cfg).noiseScale, in: 0.5...2.5)
            }
        }

        GroupBox("Nebula — Color & Body") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)

                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation))
                    .font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)

                LabeledContent("Body Void", value: String(format: "%.2f", cfg.bodyVoid))
                    .font(.caption)
                Slider(value: Bindable(cfg).bodyVoid, in: 0...1)

                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling))
                    .font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var strandVeilSection: some View {
        let cfg = manager.strandVeil
        GroupBox("Strand Veil — Density") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Strands", value: "\(cfg.strandCount / 1000)k")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.strandCount) },
                        set: { cfg.strandCount = Int($0) }
                    ),
                    in: 1000...16000, step: 500
                )

                LabeledContent("Length", value: String(format: "%.2f", cfg.strandLength))
                    .font(.caption)
                Slider(value: Bindable(cfg).strandLength, in: 0.5...2.5)
            }
        }

        GroupBox("Strand Veil — Flow") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Flow Scale", value: String(format: "%.2f", cfg.flowScale))
                    .font(.caption)
                Slider(value: Bindable(cfg).flowScale, in: 0.2...2.0)

                LabeledContent("Bass→Flow", value: String(format: "%.2f", cfg.flowAudioMod))
                    .font(.caption)
                Slider(value: Bindable(cfg).flowAudioMod, in: 0...2)

                LabeledContent("Gravity", value: String(format: "%.2f", cfg.gravity))
                    .font(.caption)
                Slider(value: Bindable(cfg).gravity, in: 0...1)
            }
        }

        GroupBox("Strand Veil — Color") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)

                LabeledContent("Hue Spread", value: String(format: "%.2f", cfg.hueSpread))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueSpread, in: 0...1)

                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling))
                    .font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
            }
        }
    }

    @ViewBuilder
    private var sandMandalaSection: some View {
        let cfg = manager.sandMandala
        GroupBox("Sand Mandala — Density") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Grains", value: "\(cfg.grainCount / 1000)k")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.grainCount) },
                        set: { cfg.grainCount = Int($0) }
                    ),
                    in: 1024...262144, step: 4096
                )
            }
        }

        GroupBox("Sand Mandala — Pattern") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Symmetry", value: String(format: "%.0f-fold", cfg.symmetry))
                    .font(.caption)
                Slider(value: Bindable(cfg).symmetry, in: 4...16, step: 1)

                LabeledContent("Ring Scale", value: String(format: "%.2f", cfg.ringScale))
                    .font(.caption)
                Slider(value: Bindable(cfg).ringScale, in: 0.20...0.70)

                LabeledContent("Rotate Speed", value: String(format: "%.4f", cfg.rotationSpeed))
                    .font(.caption)
                Slider(value: Bindable(cfg).rotationSpeed, in: 0...0.01)
            }
        }

        GroupBox("Sand Mandala — Physics") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Spring K", value: String(format: "%.3f", cfg.springK))
                    .font(.caption)
                Slider(value: Bindable(cfg).springK, in: 0.005...0.05)

                LabeledContent("Damping", value: String(format: "%.3f", cfg.damping))
                    .font(.caption)
                Slider(value: Bindable(cfg).damping, in: 0.85...0.96)

                LabeledContent("Onset Morph", value: String(format: "%.2f", cfg.onsetMorph))
                    .font(.caption)
                Slider(value: Bindable(cfg).onsetMorph, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var mocapConstellationSection: some View {
        let cfg = manager.mocapConstellation
        GroupBox("Mocap Constellation — Emission") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Rate", value: String(format: "%.2fs", cfg.emissionRate))
                    .font(.caption)
                Slider(value: Bindable(cfg).emissionRate, in: 0.02...0.5)

                LabeledContent("Lifespan", value: String(format: "%.1fs", cfg.starLifespan))
                    .font(.caption)
                Slider(value: Bindable(cfg).starLifespan, in: 2...15)
            }
        }

        GroupBox("Mocap Constellation — Stars") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Core Size", value: String(format: "%.0f", cfg.starCoreSize))
                    .font(.caption)
                Slider(value: Bindable(cfg).starCoreSize, in: 500...3000)

                LabeledContent("Ring Growth", value: String(format: "%.2f", cfg.ringGrowth))
                    .font(.caption)
                Slider(value: Bindable(cfg).ringGrowth, in: 0...0.5)

                LabeledContent("Ring Width", value: String(format: "%.3f", cfg.ringWidth))
                    .font(.caption)
                Slider(value: Bindable(cfg).ringWidth, in: 0.005...0.04)

                LabeledContent("Audio →", value: String(format: "%.2f", cfg.audioCoupling))
                    .font(.caption)
                Slider(value: Bindable(cfg).audioCoupling, in: 0...2)
            }
        }

        GroupBox("Mocap Constellation — Color") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Per-joint hues", isOn: Bindable(cfg).randomizeHue)
                    .font(.callout)

                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var bodyOfPetalsSection: some View {
        let cfg = manager.bodyOfPetals
        GroupBox("Body of Petals — Field") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Petal Size", value: String(format: "%.3f", cfg.petalSize))
                    .font(.caption)
                Slider(value: Bindable(cfg).petalSize, in: 0.020...0.080)

                LabeledContent("Density", value: String(format: "%.2f", cfg.density))
                    .font(.caption)
                Slider(value: Bindable(cfg).density, in: 0...1)

                LabeledContent("Fall Speed", value: String(format: "%.3f", cfg.fallSpeed))
                    .font(.caption)
                Slider(value: Bindable(cfg).fallSpeed, in: 0...0.5)

                LabeledContent("Bass→Fall", value: String(format: "%.2f", cfg.bassFall))
                    .font(.caption)
                Slider(value: Bindable(cfg).bassFall, in: 0...0.30)
            }
        }

        GroupBox("Body of Petals — Palette") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Hue A", value: String(format: "%.2f", cfg.hueA))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueA, in: 0...1)

                LabeledContent("Hue B", value: String(format: "%.2f", cfg.hueB))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueB, in: 0...1)

                LabeledContent("Hue C", value: String(format: "%.2f", cfg.hueC))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueC, in: 0...1)

                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation))
                    .font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)

                LabeledContent("Sub-Surface", value: String(format: "%.2f", cfg.subSurface))
                    .font(.caption)
                Slider(value: Bindable(cfg).subSurface, in: 0...1)
            }
        }

        GroupBox("Body of Petals — Body & Beats") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Body Avoid", value: String(format: "%.2f", cfg.bodyAvoidance))
                    .font(.caption)
                Slider(value: Bindable(cfg).bodyAvoidance, in: 0...2)

                LabeledContent("Onset Bouquet", value: String(format: "%.2f", cfg.onsetBouquet))
                    .font(.caption)
                Slider(value: Bindable(cfg).onsetBouquet, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var mandelbulbAviarySection: some View {
        let cfg = manager.mandelbulbAviary
        GroupBox("Mandelbulb — Fractal") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Power", value: String(format: "%.1f", cfg.fractalPower))
                    .font(.caption)
                Slider(value: Bindable(cfg).fractalPower, in: 5...12)

                LabeledContent("Audio Mod", value: String(format: "%.2f", cfg.powerAudioMod))
                    .font(.caption)
                Slider(value: Bindable(cfg).powerAudioMod, in: 0...3)

                LabeledContent("Steps", value: "\(cfg.raymarchSteps)")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.raymarchSteps) },
                        set: { cfg.raymarchSteps = Int($0) }
                    ),
                    in: 30...80, step: 1
                )

                LabeledContent("Hue", value: String(format: "%.2f", cfg.fractalHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).fractalHue, in: 0...1)

                LabeledContent("Cam Speed", value: String(format: "%.2f", cfg.camOrbitSpeed))
                    .font(.caption)
                Slider(value: Bindable(cfg).camOrbitSpeed, in: 0...0.30)
            }
        }

        GroupBox("Mandelbulb — Flock") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Birds", value: "\(cfg.birdCount)")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.birdCount) },
                        set: { cfg.birdCount = Int($0) }
                    ),
                    in: 20...120, step: 1
                )

                LabeledContent("Bird Size", value: String(format: "%.3f", cfg.birdSize))
                    .font(.caption)
                Slider(value: Bindable(cfg).birdSize, in: 0.001...0.020)

                LabeledContent("Body Attract", value: String(format: "%.2f", cfg.birdBodyAttract))
                    .font(.caption)
                Slider(value: Bindable(cfg).birdBodyAttract, in: 0...1)

                LabeledContent("Bird Hue", value: String(format: "%.2f", cfg.birdHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).birdHue, in: 0...1)
            }
        }
    }

    @ViewBuilder
    private var mercuryStormSection: some View {
        let cfg = manager.mercuryStorm
        GroupBox("Mercury Storm — Field") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Ball Count", value: "\(cfg.ballCount)")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.ballCount) },
                        set: { cfg.ballCount = Int($0) }
                    ),
                    in: 4...16, step: 1
                )

                LabeledContent("Orbit Radius", value: String(format: "%.2f", cfg.orbitRadius))
                    .font(.caption)
                Slider(value: Bindable(cfg).orbitRadius, in: 0.10...0.45)

                LabeledContent("Ball Radius", value: String(format: "%.3f", cfg.ballRadius))
                    .font(.caption)
                Slider(value: Bindable(cfg).ballRadius, in: 0.04...0.20)

                LabeledContent("Body Emit", value: String(format: "%.2f", cfg.bodyEmit))
                    .font(.caption)
                Slider(value: Bindable(cfg).bodyEmit, in: 0...3)
            }
        }

        GroupBox("Mercury Storm — Chrome") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)

                LabeledContent("Streak", value: String(format: "%.2f", cfg.streakIntensity))
                    .font(.caption)
                Slider(value: Bindable(cfg).streakIntensity, in: 0...1)

                LabeledContent("Specular", value: String(format: "%.0f", cfg.specularTightness))
                    .font(.caption)
                Slider(value: Bindable(cfg).specularTightness, in: 8...128)

                LabeledContent("Onset Vortex", value: String(format: "%.2f", cfg.onsetVortex))
                    .font(.caption)
                Slider(value: Bindable(cfg).onsetVortex, in: 0...1)
            }
        }
    }

    // — Universal Controls — six modifiers that affect every visualizer:
    //   • Audio Reactive toggle + slider (drives AudioEngine.outputMultiplier)
    //   • Speed (scales the time input every viz reads)
    //   • Hue Shift / Saturation / Brightness / Glow (post-process pass)
    @ViewBuilder
    private var universalControlsSection: some View {
        let common = manager.common

        GroupBox("Universal Controls") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Audio Reactive", isOn: Bindable(common).audioReactiveOn)
                    .font(.callout)

                LabeledContent("Audio", value: String(format: "%.2f", common.audioReactivity))
                    .font(.caption)
                Slider(value: Bindable(common).audioReactivity, in: 0...1.5)

                LabeledContent("Speed", value: String(format: "%.2f×", common.speedMul))
                    .font(.caption)
                Slider(value: Bindable(common).speedMul, in: 0...3)

                Divider()

                LabeledContent("Hue Shift", value: String(format: "%+.2f", common.hueShift))
                    .font(.caption)
                Slider(value: Bindable(common).hueShift, in: -0.5...0.5)

                LabeledContent("Saturation", value: String(format: "%.2f×", common.saturationMul))
                    .font(.caption)
                Slider(value: Bindable(common).saturationMul, in: 0...2)

                LabeledContent("Brightness", value: String(format: "%.2f×", common.brightnessMul))
                    .font(.caption)
                Slider(value: Bindable(common).brightnessMul, in: 0...2)

                LabeledContent("Glow", value: String(format: "%.2f×", common.glowMul))
                    .font(.caption)
                Slider(value: Bindable(common).glowMul, in: 0...3)

                Button("Reset to neutral") {
                    common.audioReactivity = 1.0
                    common.speedMul = 1.0
                    common.hueShift = 0
                    common.saturationMul = 1.0
                    common.brightnessMul = 1.0
                    common.glowMul = 1.0
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // — Particle Storm controls — 256k curl-noise advected particles. Knobs
    //   cover density, motion field, body coupling, and color palette.
    @ViewBuilder
    private var particleStormSection: some View {
        let cfg = manager.particleStorm

        GroupBox("Particle Storm — Density") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Particles", value: "\(cfg.particleCount / 1000)k")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.particleCount) },
                        set: { cfg.particleCount = Int($0) }
                    ),
                    in: 1024...262144, step: 4096
                )

                LabeledContent("Point Size", value: String(format: "%.1f", cfg.pointSizeBase))
                    .font(.caption)
                Slider(value: Bindable(cfg).pointSizeBase, in: 0.5...6.0)

                LabeledContent("Speed→Size", value: String(format: "%.1f", cfg.speedToSize))
                    .font(.caption)
                Slider(value: Bindable(cfg).speedToSize, in: 0...30)
            }
        }

        GroupBox("Particle Storm — Motion") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Curl Scale", value: String(format: "%.2f", cfg.curlScale))
                    .font(.caption)
                Slider(value: Bindable(cfg).curlScale, in: 0.3...3.0)

                LabeledContent("Accel Gain", value: String(format: "%.2f", cfg.accelGain))
                    .font(.caption)
                Slider(value: Bindable(cfg).accelGain, in: 0...3)

                LabeledContent("Damping", value: String(format: "%.3f", cfg.damping))
                    .font(.caption)
                Slider(value: Bindable(cfg).damping, in: 0.85...0.99)

                LabeledContent("Jitter", value: String(format: "%.2f", cfg.jitterAmount))
                    .font(.caption)
                Slider(value: Bindable(cfg).jitterAmount, in: 0...1)

                LabeledContent("Recycle Age", value: String(format: "%.0f", cfg.recycleAge))
                    .font(.caption)
                Slider(value: Bindable(cfg).recycleAge, in: 100...600)
            }
        }

        GroupBox("Particle Storm — Body & Beats") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Body Pull", value: String(format: "%.2f", cfg.bodyPull))
                    .font(.caption)
                Slider(value: Bindable(cfg).bodyPull, in: 0...3)

                LabeledContent("Onset Burst", value: String(format: "%.2f", cfg.onsetBurst))
                    .font(.caption)
                Slider(value: Bindable(cfg).onsetBurst, in: 0...5)
            }
        }

        GroupBox("Particle Storm — Color") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Base Hue", value: String(format: "%.2f", cfg.baseHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)

                LabeledContent("Spread", value: String(format: "%.2f", cfg.hueSpread))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueSpread, in: 0...1)

                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation))
                    .font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)
            }
        }
    }

    // — Parametric Swarm controls — Casberry-style knobs for shape, palette,
    //   density, glow, and Kinect-body integration.
    @ViewBuilder
    private var parametricSwarmSection: some View {
        let cfg = manager.parametricSwarm

        GroupBox("Swarm Shape") {
            Picker("Formation", selection: Bindable(cfg).formation) {
                ForEach(SwarmFormation.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }

        GroupBox("Visual Style") {
            Picker("Style", selection: Bindable(cfg).style) {
                ForEach(SwarmStyle.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        GroupBox("Color") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Hue", value: String(format: "%.2f", cfg.baseHue))
                    .font(.caption)
                Slider(value: Bindable(cfg).baseHue, in: 0...1)

                LabeledContent("Spread", value: String(format: "%.2f", cfg.hueSpread))
                    .font(.caption)
                Slider(value: Bindable(cfg).hueSpread, in: 0...0.5)

                LabeledContent("Saturation", value: String(format: "%.2f", cfg.saturation))
                    .font(.caption)
                Slider(value: Bindable(cfg).saturation, in: 0...1)

                LabeledContent("Brightness", value: String(format: "%.2f", cfg.value))
                    .font(.caption)
                Slider(value: Bindable(cfg).value, in: 0.2...1.6)
            }
        }

        GroupBox("Density & Glow") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Particles", value: "\(cfg.particleCount)")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(cfg.particleCount) },
                        set: { cfg.particleCount = Int($0) }
                    ),
                    in: 1024...65536, step: 1024
                )

                LabeledContent("Particle Size", value: String(format: "%.1f", cfg.particleSize))
                    .font(.caption)
                Slider(value: Bindable(cfg).particleSize, in: 0.5...6.0)

                LabeledContent("Glow Intensity", value: String(format: "%.1f", cfg.glowIntensity))
                    .font(.caption)
                Slider(value: Bindable(cfg).glowIntensity, in: 0.3...3.0)
            }
        }

        GroupBox("Audio & Body") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Audio Reactivity", value: String(format: "%.2f", cfg.audioReactivity))
                    .font(.caption)
                Slider(value: Bindable(cfg).audioReactivity, in: 0...1.5)

                LabeledContent("Body Attraction", value: String(format: "%.2f", cfg.bodyAttraction))
                    .font(.caption)
                Slider(value: Bindable(cfg).bodyAttraction, in: 0...1.5)

                LabeledContent("Rotate Speed", value: String(format: "%.2f", cfg.rotateSpeed))
                    .font(.caption)
                Slider(value: Bindable(cfg).rotateSpeed, in: 0...0.6)
            }
        }
    }
}
