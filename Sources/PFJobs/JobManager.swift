import Foundation
import IOKit.ps
import PFCore

// MARK: - Job model

public enum JobPriority: Int, Sendable, Comparable, Codable {
    case background = 0, utility = 1, userInitiated = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var taskPriority: TaskPriority {
        switch self { case .background: .background; case .utility: .utility; case .userInitiated: .userInitiated }
    }
}

public enum JobStatus: String, Sendable, Codable { case queued, running, paused, succeeded, failed, cancelled }

public struct JobProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var message: String            // "Analyzing 14,250 of 52,000 images"
    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

public enum JobEvent: Sendable {
    case queued(UUID, kind: String)
    case started(UUID)
    case progress(UUID, JobProgress)
    case finished(UUID, JobStatus, error: String?)
    case throttled(reason: String?)       // nil = back to normal
}

/// A unit of resumable work. Implementations must be idempotent per item and call
/// `context.checkpoint()` between items so pause/cancel take effect promptly.
public protocol BackgroundJob: Sendable {
    var kind: String { get }
    var priority: JobPriority { get }
    var maxRetries: Int { get }
    func run(_ context: JobContext) async throws
}
public extension BackgroundJob { var maxRetries: Int { 2 } }

/// Persists job rows (the `jobs` table) so work resumes after quit/crash.
public protocol JobStore: Sendable {
    func save(id: UUID, kind: String, priority: JobPriority, status: JobStatus,
              progress: Double, message: String?, retryCount: Int, error: String?) async
}

// MARK: - Context handed to jobs

public struct JobContext: Sendable {
    public let id: UUID
    let manager: JobManager

    /// Suspends while paused or throttled-to-zero; throws if cancelled.
    public func checkpoint() async throws {
        try Task.checkCancellation()
        await manager.waitIfPaused(id)
        try Task.checkCancellation()
    }

    public func report(_ completed: Int, of total: Int, _ verb: String = "Analyzing", noun: String = "images") async {
        let f = NumberFormatter(); f.numberStyle = .decimal
        let msg = "\(verb) \(f.string(from: completed as NSNumber) ?? "\(completed)") of \(f.string(from: total as NSNumber) ?? "\(total)") \(noun)"
        await manager.progress(id, JobProgress(completed: completed, total: total, message: msg))
    }

    public func report(message: String) async {
        await manager.progress(id, JobProgress(completed: 0, total: 0, message: message))
    }

    /// Current parallelism budget for per-item TaskGroups inside the job.
    public func concurrencyBudget() async -> Int { await manager.currentConcurrency }
}

// MARK: - Manager

/// Priority scheduler for indexing work. Respects thermal state, Low Power Mode,
/// battery, and memory pressure; every job is pausable and cancellable.
public actor JobManager {
    private struct Entry {
        let id: UUID
        let job: any BackgroundJob
        var status: JobStatus
        var retries = 0
        var task: Task<Void, Never>?
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var globallyPaused = false
    private var pausedJobs: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var memoryPressure = false
    private let maxConcurrentJobs: Int
    private let store: (any JobStore)?
    private let eventContinuation: AsyncStream<JobEvent>.Continuation
    private var memorySource: DispatchSourceMemoryPressure?
    public nonisolated let events: AsyncStream<JobEvent>

    public init(maxConcurrentJobs: Int = 2, store: (any JobStore)? = nil) {
        self.maxConcurrentJobs = maxConcurrentJobs
        self.store = store
        (events, eventContinuation) = AsyncStream.makeStream(of: JobEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Call once after init to hook system signals.
    public func startMonitoringSystem() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in
            let level = src.data
            Task { await self?.setMemoryPressure(level.contains(.warning) || level.contains(.critical)) }
        }
        src.resume()
        memorySource = src
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                await self?.systemConditionsChanged()
            }
        }
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                await self?.systemConditionsChanged()
            }
        }
    }

    // MARK: Public API

    @discardableResult
    public func enqueue(_ job: any BackgroundJob) async -> UUID {
        let id = UUID()
        entries[id] = Entry(id: id, job: job, status: .queued)
        order.append(id)
        eventContinuation.yield(.queued(id, kind: job.kind))
        await persist(id)
        schedule()
        return id
    }

    public func cancel(_ id: UUID) async {
        guard let e = entries[id] else { return }
        if let task = e.task {
            // Running (possibly paused mid-way): cancel and wake it; its catch path calls finish().
            task.cancel()
            resumeWaiters(id)
        } else if e.status == .queued || e.status == .paused {
            await finish(id, .cancelled, error: nil)
        }
    }

    public func pause(_ id: UUID? = nil) {
        if let id { pausedJobs.insert(id); entries[id]?.status = .paused } else { globallyPaused = true }
    }

    public func resume(_ id: UUID? = nil) {
        if let id {
            pausedJobs.remove(id)
            if entries[id]?.status == .paused { entries[id]?.status = entries[id]?.task == nil ? .queued : .running }
            resumeWaiters(id)
        } else {
            globallyPaused = false
            for k in Array(waiters.keys) where !pausedJobs.contains(k) { resumeWaiters(k) }
        }
        schedule()
    }

    // MARK: System conditions

    /// Items processed in parallel *within* a job.
    public var currentConcurrency: Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        if memoryPressure { return 1 }
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return 0            // pause-equivalent
        case .serious: return 1
        case .fair: return max(1, cores / 2)
        default: break
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled || Self.onBattery() { return max(1, cores / 3) }
        return cores
    }

    private func setMemoryPressure(_ on: Bool) { memoryPressure = on; systemConditionsChanged() }

    private func systemConditionsChanged() {
        let c = currentConcurrency
        eventContinuation.yield(.throttled(reason: c == 0 ? "Paused: Mac is too hot"
                                            : memoryPressure ? "Reduced: memory pressure"
                                            : Self.onBattery() ? "Reduced: on battery" : nil))
        if c > 0 { for k in Array(waiters.keys) where !isPaused(k) { resumeWaiters(k) } }
        schedule()
    }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    // MARK: Internals used by JobContext

    func waitIfPaused(_ id: UUID) async {
        while isPaused(id) || currentConcurrency == 0 {
            if entries[id]?.task?.isCancelled == true { return }
            await withCheckedContinuation { waiters[id, default: []].append($0) }
        }
    }

    func progress(_ id: UUID, _ p: JobProgress) async {
        eventContinuation.yield(.progress(id, p))
        await store?.save(id: id, kind: entries[id]?.job.kind ?? "", priority: entries[id]?.job.priority ?? .utility,
                          status: entries[id]?.status ?? .running, progress: p.fraction, message: p.message,
                          retryCount: entries[id]?.retries ?? 0, error: nil)
    }

    private func isPaused(_ id: UUID) -> Bool { globallyPaused || pausedJobs.contains(id) }

    private func resumeWaiters(_ id: UUID) {
        let ws = waiters.removeValue(forKey: id) ?? []
        ws.forEach { $0.resume() }
    }

    private func schedule() {
        guard !globallyPaused, currentConcurrency > 0 else { return }
        let running = entries.values.filter { $0.status == .running }.count
        var slots = maxConcurrentJobs - running
        guard slots > 0 else { return }
        let ready = order.compactMap { entries[$0] }
            .filter { $0.status == .queued && !pausedJobs.contains($0.id) }
            .sorted { $0.job.priority > $1.job.priority }      // stable: FIFO within a priority
        for e in ready where slots > 0 {
            start(e.id); slots -= 1
        }
    }

    private func start(_ id: UUID) {
        guard var e = entries[id] else { return }
        e.status = .running
        let job = e.job
        let ctx = JobContext(id: id, manager: self)
        e.task = Task(priority: job.priority.taskPriority) { [weak self] in
            do {
                try await job.run(ctx)
                await self?.finish(id, .succeeded, error: nil)
            } catch is CancellationError {
                await self?.finish(id, .cancelled, error: nil)
            } catch PhotoForgeError.cancelled {
                await self?.finish(id, .cancelled, error: nil)
            } catch {
                await self?.failed(id, error)
            }
        }
        entries[id] = e
        eventContinuation.yield(.started(id))
    }

    private func failed(_ id: UUID, _ error: Error) async {
        guard var e = entries[id] else { return }
        if e.retries < e.job.maxRetries {
            e.retries += 1
            e.status = .queued
            e.task = nil
            entries[id] = e
            // Exponential back-off before the retry becomes eligible.
            let delay = UInt64(pow(2.0, Double(e.retries))) * 1_000_000_000
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                await self?.kick()
            }
        } else {
            await finish(id, .failed, error: String(describing: error))
        }
    }

    private func kick() { schedule() }

    private func finish(_ id: UUID, _ status: JobStatus, error: String?) async {
        entries[id]?.status = status
        entries[id]?.task = nil
        resumeWaiters(id)
        eventContinuation.yield(.finished(id, status, error: error))
        await persist(id, error: error)
        order.removeAll { $0 == id }
        schedule()
    }

    private func persist(_ id: UUID, error: String? = nil) async {
        guard let e = entries[id] else { return }
        await store?.save(id: id, kind: e.job.kind, priority: e.job.priority, status: e.status,
                          progress: e.status == .succeeded ? 1 : 0, message: nil, retryCount: e.retries, error: error)
    }
}

// MARK: - Example job: stage-2 hashing over assets that still need it

/// Shows the per-item pattern every indexing stage follows: fetch the work list,
/// process in bounded parallel batches, checkpoint between batches, persist results.
public struct HashingJob: BackgroundJob {
    public let kind = "hash.perceptual"
    public let priority: JobPriority = .utility
    let pending: @Sendable () async throws -> [String]                         // PhotoKit ids lacking stage bit
    let process: @Sendable (String) async throws -> Void                       // load 512px, hash, measure, save
    public init(pending: @escaping @Sendable () async throws -> [String],
                process: @escaping @Sendable (String) async throws -> Void) {
        self.pending = pending; self.process = process
    }

    public func run(_ ctx: JobContext) async throws {
        let ids = try await pending()
        var done = 0
        var cursor = 0
        while cursor < ids.count {
            try await ctx.checkpoint()
            let width = max(1, await ctx.concurrencyBudget())
            let batch = ids[cursor..<min(cursor + width * 4, ids.count)]
            try await withThrowingTaskGroup(of: Void.self) { group in
                var it = batch.makeIterator()
                for _ in 0..<width { if let id = it.next() { group.addTask { try await Self.tolerant(process, id) } } }
                while try await group.next() != nil {
                    if let id = it.next() { group.addTask { try await Self.tolerant(process, id) } }
                }
            }
            cursor += batch.count
            done += batch.count
            await ctx.report(done, of: ids.count)
        }
    }

    /// Per-item failures (iCloud-only, corrupt file) are recorded, not fatal to the job.
    static func tolerant(_ process: @Sendable (String) async throws -> Void, _ id: String) async throws {
        do { try await process(id) }
        catch is CancellationError { throw CancellationError() }
        catch PhotoForgeError.cancelled { throw CancellationError() }
        catch { /* the process closure records the per-asset error state */ }
    }
}
