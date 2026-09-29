import Foundation
import Metal
import CoreML
import IOKit

/// What this Mac is, read at launch (and whenever the hardware changes, e.g. after
/// moving to a new Mac with Migration Assistant), and the settings PhotoForge derives
/// from it. The universal app runs natively on Intel and on every Apple Silicon Mac.
struct MachineProfile: Codable, Equatable, Sendable {
    enum Tier: String, Codable, Sendable {
        case intelLow, intel, appleBase, applePro, appleMax
        var label: String {
            switch self {
            case .intelLow: "Intel (economy)"
            case .intel: "Intel"
            case .appleBase: "Apple silicon"
            case .applePro: "Apple silicon Pro"
            case .appleMax: "Apple silicon Max/Ultra"
            }
        }
    }

    var chip: String               // "Apple M3 Pro" / "Intel(R) Core(TM) i5-5287U CPU @ 2.90GHz"
    var model: String              // "MacBookPro12,1"
    var isAppleSilicon: Bool
    var isTranslated: Bool         // running under Rosetta (shouldn't happen: the app is universal)
    var cores: Int
    var performanceCores: Int
    var memoryGB: Int
    var gpu: String
    var hasNeuralEngine: Bool
    var macOS: String
    var tier: Tier

    // Derived settings
    var analysisConcurrency: Int
    var ocrAccurate: Bool
    var classifyImageSize: Int
    var faceImageSize: Int
    var thumbnailCacheMB: Int
    var computeUnits: String       // "all" (CPU+GPU+Neural Engine) or "cpuAndGPU"
    var recommendedUpscaler: String

    static func detect() -> MachineProfile {
        func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
            return String(cString: buf)
        }
        func sysctlInt(_ name: String) -> Int? {
            var v: Int64 = 0; var size = MemoryLayout<Int64>.size
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else {
                var v32: Int32 = 0; var s32 = MemoryLayout<Int32>.size
                return sysctlbyname(name, &v32, &s32, nil, 0) == 0 ? Int(v32) : nil
            }
            return Int(v)
        }
        let arm = (sysctlInt("hw.optional.arm64") ?? 0) == 1
        let translated = (sysctlInt("sysctl.proc_translated") ?? 0) == 1
        let chip = sysctlString("machdep.cpu.brand_string") ?? (arm ? "Apple silicon" : "Intel")
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let pcores = sysctlInt("hw.perflevel0.physicalcpu") ?? (sysctlInt("hw.physicalcpu") ?? cores)
        let mem = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let gpu = MTLCreateSystemDefaultDevice()?.name ?? "Unknown GPU"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"

        let tier: Tier
        if arm {
            let c = chip.lowercased()
            tier = c.contains("max") || c.contains("ultra") ? .appleMax : (c.contains("pro") ? .applePro : .appleBase)
        } else {
            tier = (cores <= 4 || mem <= 8) ? .intelLow : .intel
        }
        var p = MachineProfile(
            chip: chip, model: sysctlString("hw.model") ?? "Mac", isAppleSilicon: arm, isTranslated: translated,
            cores: cores, performanceCores: pcores, memoryGB: mem, gpu: gpu, hasNeuralEngine: arm, macOS: os, tier: tier,
            analysisConcurrency: 2, ocrAccurate: false, classifyImageSize: 1024, faceImageSize: 1280,
            thumbnailCacheMB: 150, computeUnits: "cpuAndGPU", recommendedUpscaler: "fast")
        switch tier {
        case .intelLow:
            // Dual-core Intel: one photo at a time leaves a core free for the window.
            p.analysisConcurrency = max(1, pcores - 1); p.classifyImageSize = 1024; p.faceImageSize = 1280; p.thumbnailCacheMB = 120
        case .intel:
            p.analysisConcurrency = max(2, min(4, cores - 2)); p.classifyImageSize = 1280; p.faceImageSize = 1600; p.thumbnailCacheMB = 250
        case .appleBase:
            p.analysisConcurrency = max(3, min(6, pcores + 1)); p.ocrAccurate = true; p.classifyImageSize = 1600
            p.faceImageSize = 2048; p.thumbnailCacheMB = mem >= 16 ? 500 : 300; p.computeUnits = "all"; p.recommendedUpscaler = "fast"
        case .applePro:
            p.analysisConcurrency = max(4, min(8, pcores)); p.ocrAccurate = true; p.classifyImageSize = 2048
            p.faceImageSize = 2048; p.thumbnailCacheMB = 800; p.computeUnits = "all"; p.recommendedUpscaler = "best"
        case .appleMax:
            p.analysisConcurrency = max(6, min(12, pcores)); p.ocrAccurate = true; p.classifyImageSize = 2048
            p.faceImageSize = 2560; p.thumbnailCacheMB = 1200; p.computeUnits = "all"; p.recommendedUpscaler = "best"
        }
        return p
    }

    var mlComputeUnits: MLComputeUnits { computeUnits == "all" ? .all : .cpuAndGPU }

    /// Short description for Settings and the first-run banner.
    var summary: String {
        "\(chip.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")) · \(cores) cores · \(memoryGB) GB"
    }

    /// Identity of the hardware, so a changed Mac triggers re-tuning.
    var fingerprint: String { "\(model)|\(chip)|\(memoryGB)|\(cores)" }
}

enum PerformanceMode: String, CaseIterable, Identifiable {
    case automatic, batterySaver, maximum
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic (tuned for this Mac)"
        case .batterySaver: "Battery saver"
        case .maximum: "Maximum speed"
        }
    }
}
