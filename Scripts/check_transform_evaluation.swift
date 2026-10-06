// Run from the repository root:
// CLANG_MODULE_CACHE_PATH=/tmp/threshold-module-cache swift Scripts/check_transform_evaluation.swift
// GPU numerical regression: compare the combined evaluator with the independent
// legacy point/DE functions, including repeated non-unit derivative recurrence.
import Foundation
import Metal

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "TransformEvaluation", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: message]) }
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let shader = try String(contentsOf: root.appendingPathComponent("Threshold/Rendering/Shaders/Common/FractalCommon.h"), encoding: .utf8)
let header = try String(contentsOf: root.appendingPathComponent("Threshold/Rendering/ShaderTypes.h"), encoding: .utf8)
let opEnd = header.range(of: "} SpaceWarpOp;")!.upperBound
let opStart = header[..<opEnd].range(of: "typedef struct", options: .backwards)!.lowerBound
let start = shader.range(of: "FORCE_INLINE float3 warpAxisNorm")!.lowerBound
let end = shader.range(of: "// The deconstructed Mandelbox")!.lowerBound
let source = """
#include <metal_stdlib>
using namespace metal;
#define FORCE_INLINE inline __attribute__((always_inline))
\(header[opStart..<opEnd])
\(shader[start..<end])
kernel void check(device float4* errors [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    SpaceWarpOp op = {};
    op.type = int(id % 22); // All built-ins and unknown identity adapters.
    uint sample = id / 22;
    op.strength = float(sample % 9) * 0.31f - 0.31f;
    op.p1 = 0.25f; op.p2 = 1.0f;
    float3 axis = normalize(float3(0.3f, 0.8f, -0.4f));
    op.axisX = axis.x; op.axisY = axis.y; op.axisZ = axis.z;
    float3 p = float3(sin(float(sample)*0.71f), cos(float(sample)*0.37f),
                      sin(float(sample)*0.13f)) * float(sample % 17) * 0.23f;
    if (sample % 31 == 0) p = float3(0.0f);
    if (sample % 31 == 1) p = axis * 1e-7f;
    if (sample % 31 == 2) p = float3(0.5f, 0, 0); // min-radius boundary
    if (sample % 31 == 3) p = float3(1, 0, 0); // max-radius boundary
    // These legacy functions are singular at the origin; test them away from
    // that singularity rather than treating existing non-finite output as a regression.
    if ((op.type == 6 || op.type == 10) && length(p) < 0.1f)
        p = float3(0.3f, 0.5f, -0.2f);
    if (op.type == 11 || op.type == 18) {
        op.p1 = -0.5f; op.p2 = 0.8660254f;
        op.axisX = -0.5773503f; op.axisY = 0.8164966f; op.axisZ = 0.2f;
    }
    float3 origin = p * 0.3f;
    float originDE = 1.7f;
    SpaceTransform fused = {p, 2.3f};
    SpaceTransform reference = fused;
    float pointError = 0, scaleError = 0;
    for (int pass = 0; pass < 8; ++pass) {
        fused = transformWarpOp(fused, origin, originDE, op);
        float d = warpOpDEUpdate(reference.point, reference.deScale, originDE, op);
        reference.point = applyWarpOp(reference.point, origin, op);
        reference.deScale = d;
        float pe = length(fused.point-reference.point) / max(1.0f, length(reference.point));
        float se = abs(fused.deScale-reference.deScale) / max(1.0f, abs(reference.deScale));
        if (!all(isfinite(fused.point)) || !isfinite(fused.deScale)
            || !all(isfinite(reference.point)) || !isfinite(reference.deScale)) {
            pointError = INFINITY; break;
        }
        pointError = max(pointError, pe); scaleError = max(scaleError, se);
    }
    errors[id] = float4(pointError, scaleError, float(op.type), float(sample));
}
"""
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("A Metal GPU is required") }
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "check")!)
let count = 22 * 4096
let buffer = device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
let queue = device.makeCommandQueue()!
let command = queue.makeCommandBuffer()!
let encoder = command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(buffer, offset: 0, index: 0)
encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
encoder.endEncoding()
command.commit()
command.waitUntilCompleted()
try require(command.status == .completed, "GPU execution failed: \(String(describing: command.error))")
let values = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
var worstPoint: Float = 0
var worstScale: Float = 0
for i in 0..<count {
    let value = values[i]
    try require(value.x.isFinite && value.y.isFinite && value.x < 2e-4 && value.y < 2e-4,
                "Mismatch: point=\(value.x), DE=\(value.y), type=\(value.z), sample=\(value.w)")
    worstPoint = max(worstPoint, value.x); worstScale = max(worstScale, value.y)
}
print("Passed \(count) GPU cases × 8 repetitions; max relative point error \(worstPoint), DE error \(worstScale)")

// Exercise the actual custom-dispatch function in both ABI modes. A deliberately
// different combined result proves that opt-in dispatch is taken; strength zero
// must bypass either implementation.
let customStart = shader.range(of: "FORCE_INLINE SpaceTransform applySpaceWarpTransform")!.lowerBound
let customEnd = shader.range(of: "FORCE_INLINE float safetyBubbleCubeDistance")!.lowerBound
for combined in [false, true] {
    let customSource = """
    #include <metal_stdlib>
    using namespace metal;
    #define FORCE_INLINE inline
    #define FC_HAS_SPACEWARP_ON true
    #define THRESHOLD_CUSTOM_SPACE_WARP
    \(combined ? "#define THRESHOLD_CUSTOM_SPACE_WARP_COMBINED" : "")
    struct SpaceTransform { float3 point; float deScale; };
    struct FractalParams {
        float spaceWarpStrength, spaceWarpParam1, spaceWarpParam2, spaceWarpParam3;
    };
    float3 customSpaceWarp(float3 p, float s, float a, float b, float c) { return p * 2; }
    float customSpaceWarpDEScale(float3 p, float s, float a, float b, float c) { return 2; }
    float3 customSpaceWarpCombined(float3 p, float s, float a, float b, float c,
                                  thread float& divisor) { divisor = 3; return p * 3; }
    \(shader[customStart..<customEnd])
    kernel void customCheck(device float4* output [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        FractalParams params = {};
        params.spaceWarpStrength = float(id);
        SpaceTransform r = applySpaceWarpTransform(float3(1), params);
        output[id] = float4(r.point, r.deScale);
    }
    """
    let customLibrary = try device.makeLibrary(source: customSource, options: nil)
    let customPipeline = try device.makeComputePipelineState(function: customLibrary.makeFunction(name: "customCheck")!)
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(customPipeline)
    enc.setBuffer(buffer, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 2, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    try require(cb.status == .completed, "Custom hook GPU execution failed")
    try require(values[0] == SIMD4<Float>(repeating: 1), "Zero strength must bypass custom hooks")
    try require(values[1] == SIMD4<Float>(repeating: combined ? 3 : 2), "Wrong custom hook dispatch")
}
print("Passed legacy/custom combined hook dispatch and zero-strength bypass")

// Optional microbenchmark, not an end-to-end frame-rate prediction. Operation
// kinds are uniform across the dispatch, as they are in the renderer.
if CommandLine.arguments.contains("--benchmark") {
    var pipelines: [MTLComputePipelineState] = []
    for legacy in [true, false] {
        let benchSource = source + """
        kernel void bench(device float4* output [[buffer(0)]],
                          constant int& kind [[buffer(1)]],
                          uint id [[thread_position_in_grid]]) {
            SpaceWarpOp op = {};
            op.type = kind; op.strength = 0.8f; op.p1 = 0.25f; op.p2 = 1.0f;
            op.axisY = 1.0f;
            float3 origin = float3(float(id % 101) * 0.021f - 1.0f, 0.3f, -0.4f);
            SpaceTransform r = {origin, 1.0f};
            for (int pass = 0; pass < 32; ++pass) {
                \(legacy ? "float d = warpOpDEUpdate(r.point, r.deScale, 1.0f, op); r.point = applyWarpOp(r.point, origin, op); r.deScale = d;" : "r = transformWarpOp(r, origin, 1.0f, op);")
                r.point = r.point * 0.5f + origin;
                r.deScale = min(r.deScale, 1000.0f);
            }
            output[id] = float4(r.point, r.deScale);
        }
        """
        let lib = try device.makeLibrary(source: benchSource, options: nil)
        pipelines.append(try device.makeComputePipelineState(function: lib.makeFunction(name: "bench")!))
    }
    for kind in [0, 1, 4, 5, 8, 17, 19] {
        var timings = [[Double](), [Double]()]
        for iteration in 0..<12 {
            // Alternate order to reduce warmup/thermal bias.
            for lane in (iteration % 2 == 0 ? [0, 1] : [1, 0]) {
                let cb = queue.makeCommandBuffer()!
                let enc = cb.makeComputeCommandEncoder()!
                let pipe = pipelines[lane]
                var rawKind = Int32(kind)
                enc.setComputePipelineState(pipe)
                enc.setBuffer(buffer, offset: 0, index: 0)
                enc.setBytes(&rawKind, length: MemoryLayout<Int32>.size, index: 1)
                enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: pipe.threadExecutionWidth, height: 1, depth: 1))
                enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
                try require(cb.status == .completed, "Benchmark GPU execution failed")
                if iteration >= 2 { timings[lane].append(cb.gpuEndTime - cb.gpuStartTime) }
            }
        }
        let old = timings[0].sorted()[5] * 1000
        let new = timings[1].sorted()[5] * 1000
        print(String(format: "Kind %d: legacy %.3f ms, combined %.3f ms (%.2fx)", kind, old, new, old/new))
    }
}
