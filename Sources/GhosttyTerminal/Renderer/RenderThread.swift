import CoreFoundation
import Foundation
import Synchronization

/// A thread with its own run loop that runs jobs in order: the serial
/// executor of a view's renderer. The display link is scheduled on the same
/// run loop, so its callbacks run isolated to the renderer.
final class RenderThread: SerialExecutor, @unchecked Sendable {
    /// CFRunLoopSourceSignal and CFRunLoopWakeUp may be called from any
    /// thread.
    private struct RunLoopHandle: @unchecked Sendable {
        let runLoop: CFRunLoop
        let source: CFRunLoopSource
    }

    private struct State: ~Copyable {
        var pending: [UnownedJob] = []
        var stopped = false
        /// Set once the thread's run loop is up.
        var handle: RunLoopHandle?
    }

    private let state = Mutex(State())
    /// Written once in init, before the thread starts.
    private nonisolated(unsafe) var thread: Thread?

    init(name: String) {
        let thread = Thread { [unowned self] in self.main() }
        thread.name = name
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func main() {
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        context.perform = { info in
            Unmanaged<RenderThread>.fromOpaque(info!).takeUnretainedValue().drain()
        }
        let source = CFRunLoopSourceCreate(nil, 0, &context)!
        let runLoop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        let handle = RunLoopHandle(runLoop: runLoop, source: source)
        state.withLock { $0.handle = handle }
        // Run what was enqueued before the run loop existed.
        CFRunLoopSourceSignal(source)
        while !state.withLock({ $0.stopped }) {
            _ = CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
    }

    private func drain() {
        let pending = state.withLock { state in
            defer { state.pending.removeAll(keepingCapacity: true) }
            return state.pending
        }
        for job in pending {
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        state.withLock { $0.pending.append(job) }
        wake()
    }

    private func wake() {
        guard let handle = state.withLock({ $0.handle }) else { return }
        CFRunLoopSourceSignal(handle.source)
        CFRunLoopWakeUp(handle.runLoop)
    }

    func checkIsolated() {
        precondition(isIsolatingCurrentContext() == true, "not on the render thread")
    }

    func isIsolatingCurrentContext() -> Bool? {
        Thread.current === thread
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Ends the thread after the jobs already enqueued.
    func stop() {
        state.withLock { $0.stopped = true }
        wake()
    }
}
