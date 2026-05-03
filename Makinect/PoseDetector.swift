// PoseDetector — Body pose detection using Apple Vision framework
//
// Uses VNDetectHumanBodyPoseRequest to detect human body joints in RGB frames.

import Vision
import AppKit

struct DetectedJoint {
    let name: VNHumanBodyPoseObservation.JointName
    let position: CGPoint  // normalized 0..1, origin bottom-left (Vision convention)
    let confidence: Float
}

struct DetectedSkeleton {
    let joints: [DetectedJoint]
}

@Observable
final class PoseDetector {
    var skeletons: [DetectedSkeleton] = []
    private var isProcessing = false

    private let requestHandler = VNSequenceRequestHandler()
    private let processingQueue = DispatchQueue(label: "com.makinect.poseDetection", qos: .userInitiated)

    func detectPose(in cgImage: CGImage) {
        // Drop frames if already processing (don't queue stale frames)
        guard !isProcessing else { return }
        isProcessing = true

        processingQueue.async { [weak self] in
            guard let self else { return }
            let request = VNDetectHumanBodyPoseRequest()
            do {
                try self.requestHandler.perform([request], on: cgImage)
                let observations = request.results ?? []
                let detected = observations.compactMap { self.extractSkeleton(from: $0) }
                DispatchQueue.main.async {
                    self.skeletons = detected
                    self.isProcessing = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.skeletons = []
                    self.isProcessing = false
                }
            }
        }
    }

    private func extractSkeleton(from observation: VNHumanBodyPoseObservation) -> DetectedSkeleton? {
        let jointNames: [VNHumanBodyPoseObservation.JointName] = [
            .nose, .neck,
            .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow,
            .leftWrist, .rightWrist,
            .root,
            .leftHip, .rightHip,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle,
        ]
        var joints: [DetectedJoint] = []
        for name in jointNames {
            if let point = try? observation.recognizedPoint(name), point.confidence > 0.1 {
                joints.append(DetectedJoint(
                    name: name,
                    position: point.location,
                    confidence: point.confidence
                ))
            }
        }
        return joints.isEmpty ? nil : DetectedSkeleton(joints: joints)
    }
}
