//
//  RendererTaskExecutor.swift
//  MetalProject
//
//  Extracted from Renderer.swift
//

import Foundation
import Synchronization

/// Dedicated render thread using a persistent Thread object with high priority.
/// This avoids thread hopping and preemption that causes micro-stutters with DispatchQueue.
///
/// @unchecked Sendable justification: mutable job queue is protected by Mutex;
/// DispatchSemaphore is used for blocking thread wake-up (not in async context);
/// isRunning is only written during init and never changes.
final class RendererTaskExecutor: TaskExecutor, @unchecked Sendable {
    private struct JobQueue {
        var jobs: [UnownedJob] = []
        var head: Int = 0
        let compactionThreshold = 64

        mutating func enqueue(_ job: UnownedJob) {
            jobs.append(job)
        }

        mutating func dequeue() -> UnownedJob? {
            guard head < jobs.count else {
                jobs.removeAll(keepingCapacity: true)
                head = 0
                return nil
            }
            let job = jobs[head]
            head += 1
            if head >= compactionThreshold && head >= jobs.count / 2 {
                jobs.removeFirst(head)
                head = 0
            }
            return job
        }
    }

    private let _queue = Mutex(JobQueue())
    // DispatchSemaphore is intentionally used here for blocking thread wake-up.
    // This is a raw Thread (not async context), so semaphore is the correct primitive.
    private let semaphore = DispatchSemaphore(value: 0)
    private let isRunning = true
    private var renderThread: Thread?
    
    init() {
        let executor = self
        renderThread = Thread { [weak executor] in
            Thread.current.qualityOfService = .userInteractive
            Thread.current.threadPriority = 1.0
            Thread.current.name = "RenderThread"
            
            while executor?.isRunning ?? false {
                executor?.semaphore.wait()
                
                while let job = executor?._queue.withLock({ $0.dequeue() }) {
                    job.runSynchronously(on: executor!.asUnownedSerialExecutor())
                }
            }
        }
        renderThread?.qualityOfService = .userInteractive
        renderThread?.start()
    }

    func enqueue(_ job: UnownedJob) {
        _queue.withLock { $0.enqueue(job) }
        semaphore.signal()
    }

    func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        return UnownedTaskExecutor(ordinary: self)
    }

    nonisolated(unsafe) static var shared: RendererTaskExecutor = RendererTaskExecutor()
}
