// SkeletonOverlayView — SwiftUI Canvas overlay for rendering detected body skeletons

import SwiftUI
import Vision

struct SkeletonOverlayView: View {
    let skeletons: [DetectedSkeleton]
    let imageSize: CGSize

    private let bones: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .neck),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root),
        (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                for skeleton in skeletons {
                    drawSkeleton(skeleton, in: context, viewSize: size)
                }
            }
        }
    }

    private func drawSkeleton(_ skeleton: DetectedSkeleton, in context: GraphicsContext, viewSize: CGSize) {
        let jointMap = Dictionary(uniqueKeysWithValues: skeleton.joints.map { ($0.name, $0) })

        // Draw bones (green lines)
        for (from, to) in bones {
            guard let j1 = jointMap[from], let j2 = jointMap[to] else { continue }
            let p1 = convertPoint(j1.position, viewSize: viewSize)
            let p2 = convertPoint(j2.position, viewSize: viewSize)
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(path, with: .color(.green), lineWidth: 3)
        }

        // Draw joints (yellow dots)
        for joint in skeleton.joints {
            let pt = convertPoint(joint.position, viewSize: viewSize)
            let rect = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: rect), with: .color(.yellow))
        }
    }

    /// Convert Vision normalized coords (bottom-left origin) to SwiftUI coords (top-left origin)
    /// accounting for aspect-fit scaling
    private func convertPoint(_ normalized: CGPoint, viewSize: CGSize) -> CGPoint {
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat

        if imageAspect > viewAspect {
            drawWidth = viewSize.width
            drawHeight = viewSize.width / imageAspect
            offsetX = 0
            offsetY = (viewSize.height - drawHeight) / 2
        } else {
            drawHeight = viewSize.height
            drawWidth = viewSize.height * imageAspect
            offsetX = (viewSize.width - drawWidth) / 2
            offsetY = 0
        }

        let x = offsetX + normalized.x * drawWidth
        let y = offsetY + (1 - normalized.y) * drawHeight  // Flip Y axis
        return CGPoint(x: x, y: y)
    }
}
