//
//  RendererTaskExecutor.swift
//  MetalProject
//
//  Extracted from Renderer.swift
//

import Foundation

/// Dedicated render thread using a persistent Thread object with high priority.
/// This avoids thread hopping and preemption that causes micro-stutters with DispatchQueue.
final class RendererTaskExecutor: TaskExecutor, @unchecked Sendable {
    // pendingJobs is protected by lock - safe for Sendable
    private var pendingJobs: [UnownedJob] = []
    private var pendingJobsHead: Int = 0
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var isRunning = true
    private var renderThread: Thread?
    private let pendingJobsCompactionThreshold = 64
    
    init() {
        // Create a persistent high-priority thread for rendering
        let executor = self
        renderThread = Thread { [weak executor] in
            // Set thread priority to maximum for real-time rendering
            Thread.current.qualityOfService = .userInteractive
            Thread.current.threadPriority = 1.0
            Thread.current.name = "RenderThread"
            
            while executor?.isRunning ?? false {
                // Wait for work
                executor?.semaphore.wait()
                
                // Process all pending jobs
                while let job = executor?.dequeueJob() {
                    job.runSynchronously(on: executor!.asUnownedSerialExecutor())
                }
            }
        }
        renderThread?.qualityOfService = .userInteractive
        renderThread?.start()
    }
    
    private func dequeueJob() -> UnownedJob? {
        lock.lock()
        defer { lock.unlock() }
        guard pendingJobsHead < pendingJobs.count else {
            pendingJobs.removeAll(keepingCapacity: true)
            pendingJobsHead = 0
            return nil
        }

        let job = pendingJobs[pendingJobsHead]
        pendingJobsHead += 1
        if pendingJobsHead >= pendingJobsCompactionThreshold && pendingJobsHead >= pendingJobs.count / 2 {
            pendingJobs.removeFirst(pendingJobsHead)
            pendingJobsHead = 0
        }
        return job
    }

    func enqueue(_ job: UnownedJob) {
        lock.lock()
        pendingJobs.append(job)
        lock.unlock()
        semaphore.signal()
    }

    func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        return UnownedTaskExecutor(ordinary: self)
    }

    static var shared: RendererTaskExecutor = RendererTaskExecutor()
}
