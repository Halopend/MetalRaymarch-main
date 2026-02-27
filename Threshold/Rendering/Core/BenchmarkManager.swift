import Foundation

#if DEBUG
class BenchmarkManager {
    static let shared = BenchmarkManager()
    
    var isBenchmarking = false
    
    struct FractalStats {
        var frameCount: Int = 0
        var totalGPUTime: Double = 0
        var totalCPUTime: Double = 0
        var totalFrameTime: Double = 0
        
        var minGPUTime: Double = .greatestFiniteMagnitude
        var maxGPUTime: Double = 0
        
        mutating func addSample(gpuMs: Double?, cpuMs: Double, frameTimeMs: Double) {
            frameCount += 1
            totalCPUTime += cpuMs
            totalFrameTime += frameTimeMs
            
            if let gpu = gpuMs {
                totalGPUTime += gpu
                minGPUTime = min(minGPUTime, gpu)
                maxGPUTime = max(maxGPUTime, gpu)
            }
        }
        
        func printStats(name: String) {
            let avgGPU = frameCount > 0 ? totalGPUTime / Double(frameCount) : 0
            let avgCPU = frameCount > 0 ? totalCPUTime / Double(frameCount) : 0
            let avgFrame = frameCount > 0 ? totalFrameTime / Double(frameCount) : 0
            let fps = avgFrame > 0 ? 1000.0 / avgFrame : 0
            
            print("=========================================")
            print("📊 Benchmark [\(name)]: \(frameCount) frames")
            print("   FPS: \(String(format: "%.1f", fps)) | Frame: \(String(format: "%.2f", avgFrame))ms")
            print("   GPU: Avg: \(String(format: "%.2f", avgGPU))ms | Min: \(String(format: "%.2f", minGPUTime == .greatestFiniteMagnitude ? 0 : minGPUTime))ms | Max: \(String(format: "%.2f", maxGPUTime))ms")
            print("   CPU: Avg: \(String(format: "%.2f", avgCPU))ms")
            print("=========================================")
        }
    }
    
    private var stats: [Int: FractalStats] = [:]
    
    func recordSample(fractalType: Int, fractalName: String, gpuMs: Double?, cpuMs: Double, frameTimeMs: Double) {
        guard isBenchmarking else { return }
        
        if stats[fractalType] == nil {
            stats[fractalType] = FractalStats()
        }
        
        stats[fractalType]?.addSample(gpuMs: gpuMs, cpuMs: cpuMs, frameTimeMs: frameTimeMs)
        
        // Auto-print stats every 180 frames (~2 secs at 90fps)
        if let currentStats = stats[fractalType], currentStats.frameCount % 180 == 0 {
            currentStats.printStats(name: fractalName)
        }
    }
    
    func toggleBenchmarking() {
        isBenchmarking.toggle()
        if isBenchmarking {
            print("🚀 Benchmarking STARTED")
            stats.removeAll()
        } else {
            print("🛑 Benchmarking STOPPED")
            for (type, stat) in stats.sorted(by: { $0.key < $1.key }) {
                stat.printStats(name: "FractalType \(type) Final")
            }
        }
    }
    
    func clearStats() {
        stats.removeAll()
    }
}
#endif
