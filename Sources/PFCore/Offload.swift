import Foundation

/// Runs blocking or CPU-heavy work (clustering, Vision, image decoding, big database reads)
/// on a GCD queue instead of Swift's shared cooperative thread pool.
///
/// The cooperative pool has one thread per CPU core (four on a dual-core Intel Mac). Blocking
/// those threads with long calculations made every other background task — thumbnail and
/// face-picture loading, database reads — wait in line, which looked like the app hanging.
/// GCD adds threads when work blocks, so the rest of the app keeps moving.
public enum Offload {
    public static func run<T>(_ qos: DispatchQoS.QoSClass = .userInitiated,
                                        _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: qos).async { cont.resume(returning: work()) }
        }
    }

    public static func run<T>(_ qos: DispatchQoS.QoSClass = .userInitiated,
                                        _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: qos).async { cont.resume(with: Result { try work() }) }
        }
    }
}
