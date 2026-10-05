import Darwin
import Foundation
import os

/// Lightweight self-measurement, written to the switch log once a minute so real-world cost can be
/// read without a profiler (hardened runtime rightly blocks attaching one). Counters only.
public final class PerfMeter: @unchecked Sendable {
    public static let shared = PerfMeter()

    private struct Counters {
        var frames = 0
        var faceFrames = 0
        var eyeFrames = 0
        var visionWallNs: UInt64 = 0
        var visionThreadNs: UInt64 = 0
        var eyeWallNs: UInt64 = 0
        var layouts = 0
        var layoutNs: UInt64 = 0
        var axEvents = 0
        var mouseEvents = 0
    }
    private let counters = OSAllocatedUnfairLock(initialState: Counters())
    private let last = OSAllocatedUnfairLock(initialState: (cpu: PerfMeter.processCPUSeconds(), wall: now()))

    public static func clock() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    public static func threadClock() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    public func frame(face: Bool, visionWall: UInt64, visionThread: UInt64, eyeWall: UInt64?) {
        counters.withLock { c in
            c.frames += 1
            if face { c.faceFrames += 1 }
            c.visionWallNs += visionWall
            c.visionThreadNs += visionThread
            if let eyeWall {
                c.eyeFrames += 1
                c.eyeWallNs += eyeWall
            }
        }
    }

    public func layout(_ ns: UInt64) { counters.withLock { $0.layouts += 1; $0.layoutNs += ns } }
    public func axEvent() { counters.withLock { $0.axEvents += 1 } }
    public func mouseEvent() { counters.withLock { $0.mouseEvents += 1 } }

    /// Everything since the previous report, then resets.
    public func report() -> [String: Any] {
        let c = counters.withLock { c -> Counters in defer { c = Counters() }; return c }
        let cpu = Self.processCPUSeconds(), wall = now()
        let prev = last.withLock { l -> (cpu: Double, wall: TimeInterval) in defer { l = (cpu, wall) }; return l }
        let seconds = max(wall - prev.wall, 0.001)
        func ms(_ ns: UInt64, _ n: Int) -> Double { n == 0 ? 0 : (Double(ns) / Double(n) / 1e6 * 10).rounded() / 10 }
        return [
            "seconds": Int(seconds.rounded()),
            "cpuPercent": ((cpu - prev.cpu) / seconds * 1000).rounded() / 10, // of one core
            "fps": (Double(c.frames) / seconds * 10).rounded() / 10,
            "faceShare": c.frames == 0 ? 0 : (Double(c.faceFrames) / Double(c.frames) * 100).rounded() / 100,
            "visionMs": ms(c.visionWallNs, c.frames),
            "visionThreadMs": ms(c.visionThreadNs, c.frames),
            "eyeFrames": c.eyeFrames,
            "eyeMs": ms(c.eyeWallNs, c.eyeFrames),
            "layouts": c.layouts,
            "layoutMs": ms(c.layoutNs, c.layouts),
            "axEvents": c.axEvents,
            "mouseEvents": c.mouseEvents,
            "memoryMB": Self.footprintMB(),
        ]
    }

    static func processCPUSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// The same "memory" figure Activity Monitor shows (physical footprint).
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
