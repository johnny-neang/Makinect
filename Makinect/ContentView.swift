import SwiftUI

struct ContentView: View {
    @State private var manager = KinectManager()

    var body: some View {
        HSplitView {
            // Main camera view
            ZStack {
                Color.black

                if let viz = manager.visualization {
                    MetalKinectView(manager: manager, kind: viz)
                } else if let frame = manager.currentFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    placeholderView
                }

                // Skeleton overlay (only relevant for legacy CPU mode)
                if manager.visualization == nil && shouldShowSkeleton {
                    SkeletonOverlayView(
                        skeletons: manager.poseDetector.skeletons,
                        imageSize: CGSize(width: 1920, height: 1080)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Side panel
            SidePanel(manager: manager)
                .frame(width: 240)
        }
        .frame(minWidth: 960, minHeight: 600)
    }

    private var shouldShowSkeleton: Bool {
        manager.cameraMode == .skeleton ||
        (manager.cameraMode == .rgb && manager.showSkeleton)
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
