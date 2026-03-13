import SwiftUI

struct ContentView: View {
    @State private var manager = KinectManager()

    var body: some View {
        VStack(spacing: 0) {
            // Camera feed
            ZStack {
                Color.black

                if let frame = manager.currentFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    placeholderView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Controls
            HStack(spacing: 16) {
                Picker("Mode", selection: $manager.cameraMode) {
                    ForEach(CameraMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(manager.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)

                    Text(manager.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button(manager.isConnected ? "Disconnect" : "Connect") {
                    if manager.isConnected {
                        manager.disconnect()
                    } else {
                        manager.connect()
                    }
                }
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 700, minHeight: 560)
    }

    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: manager.isConnected ? "camera" : "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(manager.statusMessage)
                .font(.title3)
                .foregroundStyle(.secondary)

            if !manager.isConnected {
                Text("Connect a Kinect sensor and press Connect")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview {
    ContentView()
}
