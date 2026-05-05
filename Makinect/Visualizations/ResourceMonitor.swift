// ResourceMonitor — observable sampler for CPU, memory, and FPS.
//
// Polls the Mach task interface every 0.5s for process-level CPU usage and
// resident memory. FPS is computed from frame deltas registered by
// MetalKinectView at the top of each draw call.
//
// All values are exposed as @Observable properties so the SwiftUI Resource
// Monitor view re-renders whenever they change.

import Foundation
import Darwin
import Observation
import QuartzCore   // CACurrentMediaTime

@Observable
final class ResourceMonitor {
    // — Live readouts (all main-thread)
    var cpuPercent: Double = 0     // 0..100 (per logical core × 100)
    var memoryMB: Double = 0       // resident size in MB
    var fps: Double = 0            // exponentially smoothed frame rate

    /// Logical core count (used to scale CPU readout to "% of total CPU").
    let coreCount: Double = Double(ProcessInfo.processInfo.activeProcessorCount)

    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var lastFrameTime: CFTimeInterval = 0

    init() {
        startSampling()
    }

    deinit { timer?.cancel() }

    // MARK: - FPS

    /// Called from MetalKinectView at the start of each draw call. Computes
    /// the inter-frame delta and updates `fps` with a fast EMA so the value
    /// stays readable but responds within ~1 second to changes.
    func registerFrame() {
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt > 0.0001 {
                let instantFPS = 1.0 / dt
                fps = fps * 0.85 + instantFPS * 0.15
            }
        }
        lastFrameTime = now
    }

    // MARK: - CPU + memory sampling

    private func startSampling() {
        let queue = DispatchQueue(label: "com.makinect.resourceMonitor", qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let cpu = Self.sampleCPUPercent()
            let mem = Self.sampleMemoryMB()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cpuPercent = cpu
                self.memoryMB = mem
            }
        }
        t.resume()
        timer = t
    }

    /// Returns the process's current CPU usage as a percentage. On a multi-
    /// core machine this can exceed 100 (it sums across threads); divide by
    /// `coreCount` to get "% of total available CPU" instead.
    private static func sampleCPUPercent() -> Double {
        var threadsList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadsList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadsList else { return 0 }
        defer {
            // Free the kernel-allocated thread array.
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }

        // Swift can't import THREAD_BASIC_INFO_COUNT (it's a sizeof macro);
        // compute the equivalent inline.
        let infoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size
        )

        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = infoCount
            let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { rebound in
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
                }
            }
            if kr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                total += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
            }
        }
        return total
    }

    private static func sampleMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }
}
