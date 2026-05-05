// SidePanel — Sidebar with connection controls, stream mode picker, and adjustable parameters

import SwiftUI

struct SidePanel: View {
    @Bindable var manager: KinectManager

    private enum TopMode: String, CaseIterable, Identifiable {
        case stream = "Stream"
        case visualize = "Visualize"
        var id: String { rawValue }
    }
    @State private var topMode: TopMode = .stream

    var body: some View {
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

        if manager.visualization == .pointCloud || manager.visualization == .voxelSculpt {
            GroupBox("Camera") {
                Text("Drag to orbit · Pinch / scroll to zoom")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if manager.visualization == .parametricSwarm {
            parametricSwarmSection
        }

        if manager.visualization == .particleStorm {
            particleStormSection
        }

        if manager.visualization == .mercuryStorm {
            mercuryStormSection
        }

        if manager.visualization == .mandelbulbAviary {
            mandelbulbAviarySection
        }

        if manager.visualization == .bodyOfPetals {
            bodyOfPetalsSection
        }

        if manager.visualization == .mocapConstellation {
            mocapConstellationSection
        }

        if manager.visualization == .sandMandala {
            sandMandalaSection
        }

        if manager.visualization == .strandVeil {
            strandVeilSection
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
