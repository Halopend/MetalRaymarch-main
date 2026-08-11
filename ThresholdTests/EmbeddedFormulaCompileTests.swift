//
//  EmbeddedFormulaCompileTests.swift
//  ThresholdTests
//
//  The strongest guard for EXTERNAL loading of scenes whose distance estimator
//  is *embedded* (custom-fractal `.threshfx` / `.threshscene` carrying an
//  `EmbeddedFormula`, and space-warp `.threshfx`). Decoding such a file is only
//  half the story — the renderer must compile the embedded Metal DE source into
//  an `MTLLibrary` at activation time (Renderer.activateEmbeddedFormula ->
//  CustomShaderCompiler.library(forFractal:spaceWarp:)). If that source has a
//  syntax error or a wrong DE signature, the scene decodes fine but renders
//  fog/sky forever with only a runtime log.
//
//  This test runs the EXACT production compile path (CustomShaderCompiler against
//  a real MTLDevice — available on the macOS test host) over every shipped
//  embedded-formula asset, so a broken embedded DE fails CI headlessly instead
//  of silently on-device.
//

import Testing
import Foundation
import Metal
@testable import Threshold

@Suite("External loading — embedded GPU effects compile to an MTLLibrary")
struct EmbeddedFormulaCompileTests {

    /// Repo `Threshold/Examples` directory, located relative to this source file.
    private static var examplesDir: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Threshold/Examples")
    }

    private static func files(withExtension ext: String, in subdirs: [String]) -> [URL] {
        var out: [URL] = []
        for sub in subdirs {
            let dir = examplesDir.appendingPathComponent(sub)
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            out += urls.filter { $0.pathExtension.lowercased() == ext }
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func iso8601Decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Every embedded formula shipped in the example assets, paired with the
    /// source file it came from for clear failure messages.
    private static func collectEmbeddedFormulas() throws -> [(source: String, formula: EmbeddedFormula)] {
        var result: [(String, EmbeddedFormula)] = []
        let decoder = iso8601Decoder()

        // Presets (scene / music-preset) may carry an embedded DE fractal.
        // Keep this list aligned with ExampleSceneDecodeTests. In particular,
        // the explicit `Custom Scene Example` directory contains the flagship
        // Polychora 24-Cell sample; it must compile through the runtime path,
        // not merely decode.
        let presetDirectories = ["Scenes", "Mixed", "Custom Scene Example", "Music Presets"]
        for url in files(withExtension: "threshscene", in: presetDirectories)
                 + files(withExtension: "threshmp", in: presetDirectories) {
            let preset = try decoder.decode(FractalPreset.self, from: Data(contentsOf: url))
            if let formula = preset.embeddedFormula {
                result.append((url.lastPathComponent, formula))
            }
            if let lighting = preset.embeddedLighting {
                result.append(("\(url.lastPathComponent) [lighting]", lighting))
            }
        }

        // `.threshfx` containers are always an embedded formula (fractal DE or
        // warp). Search every bundled example directory plus the standalone
        // Formula library, so a future example cannot bypass compile coverage
        // merely by living beside a scene instead of inside Formulas/.
        for url in files(withExtension: "threshfx", in: presetDirectories + ["Formulas"]) {
            let container = try EmbeddedFormulaContainer.decode(fromContainerAt: url)
            result.append((url.lastPathComponent, container.formula))
        }

        // Keep compatibility coverage for older builds that consume the embedded
        // source. Current builds use the precompiled construction-primitive path.
        for primitive in FractalPrimitiveKind.allCases {
            result.append(("Bundled primitive: \(primitive.name)", primitive.formula))
        }
        return result
    }

    @Test("Bundled construction primitives are valid, portable embedded formulas")
    func bundledPrimitivesValidate() throws {
        var ids = Set<String>()
        for primitive in FractalPrimitiveKind.allCases {
            let formula = primitive.formula
            try formula.validate()
            #expect(formula.effectKind == .fractal)
            #expect(formula.isBundledConstructionPrimitive)
            #expect(formula.bundledConstructionPrimitiveKind == primitive)
            #expect(ids.insert(formula.id).inserted)

            // An imported payload cannot claim the trusted/precompiled route by
            // copying only a bundled identifier.
            var spoofed = formula
            spoofed.metalSource += "\n// modified"
            #expect(!spoofed.isBundledConstructionPrimitive)
        }
    }

    /// The box payload exactly as generated before its roundness clamp gained
    /// the `size` upper bound (commit 56d01f55) — the revision embedded in every
    /// scene and auto-saved session written by earlier builds. Only the helper
    /// line differs, so reconstruct it from the current formula.
    private static var staleBoxPayload: EmbeddedFormula {
        var stale = FractalPrimitiveKind.box.formula
        stale.metalSource = stale.metalSource.replacingOccurrences(
            of: "float roundness = min(max(fp.params[1], 0.0f), size);",
            with: "float roundness = max(fp.params[1], 0.0f);"
        )
        return stale
    }

    @Test("Payloads embedded by earlier builds keep their trusted primitive identity")
    func staleBundledPayloadStillTrusted() {
        let stale = Self.staleBoxPayload
        // Guard the reconstruction itself: this hex is the ledger entry in
        // FractalPrimitiveKind.historicalBundledSourceHashes. If it mismatches,
        // the test rebuilt the wrong payload, not the one old builds shipped.
        #expect(stale.sourceHash
            == "ed1daccfbc870c8fa6915210fae8614eabd012624e2059651bc0350022105b8e")
        #expect(stale.sourceHash != FractalPrimitiveKind.box.formula.sourceHash)
        #expect(stale.bundledConstructionPrimitiveKind == .box)
    }

    @Test("Bundled payload edits must extend the historical trust ledger")
    func bundledPayloadSourceHashesArePinned() {
        // `bundledConstructionPrimitiveKind` trusts payloads by source hash, so
        // editing a shipped primitive's Metal source silently orphans every
        // scene saved by earlier builds unless the outgoing hash is kept. If a
        // pin below fails: append the hash pinned HERE (the pre-edit value) to
        // FractalPrimitiveKind.historicalBundledSourceHashes for that kind,
        // then update the pin to the new `sourceHash`. New kinds only need a
        // pin — no scenes embed them yet.
        let pinned: [FractalPrimitiveKind: String] = [
            .sphere: "741b5b3a773cc14b34b7ceacb944c352b54f7b0776b7a4f122995403266c8b3d",
            .box: "a177b1d1db51e3bf9cf0382c59e5c222d6451fbbb779d29e5d0e7663e1f2b2a4",
            .torus: "0f3cdea5c9204e59727704044142a7be4f873409ce06495cbf47e10b62475663",
            .octahedron: "4fbe1ed64ba13851b96fd1b87fe9d54221847f9976c86c2a092ffdfa68879eec",
            .capsule: "4440ffbcb8bf7ba1421f0db3af8bbc4177a41e515038f9afd84256ac70ba485a",
            .cylinder: "e18d980a6c2d2aba4f1ddabdc607a3b870d548519ad46c80a1f65e2dc283c89e",
            .cone: "b909ef549c1545c5180b4e17587531cbc84a628559ed8505be2b2fcac41f8e0d",
            .hexagonalPrism: "ecdeeaa2d3e2b461ee68a2ea344d048ca22b49d679138d043348486e0e7be0f3",
            .pyramid: "40d5e3f2823cd203c4704418ad963acb67544815686a672a31b073d2dbeb6333",
            .tetrahedron: "449b3aa1f96afbfb741786fe664332294dedce3ef1be419fe17bf3ff8380cfd1",
            .icosahedron: "6d717a8406d75a0fd33f8be082277495f3e93cb513aa591f5ddb886464777b53",
            .dodecahedron: "2bc3fdfe56f45c357ddaad9890c245c696882eee2f441bda7c8d9e6d89149325",
            .mandelboxSeed: "9503f36d41b58b08ab7adccd916dda6e1413a7bb586bb0de8996bbc16c06342b"
        ]
        for kind in FractalPrimitiveKind.allCases {
            #expect(
                kind.formula.sourceHash == pinned[kind],
                "\(kind.name) payload changed — move the old pin into historicalBundledSourceHashes before repinning"
            )
        }
        // Every ledger entry must still be recognized as its kind, and none may
        // duplicate a current payload (that would mean a pointless entry).
        for (kind, hashes) in FractalPrimitiveKind.historicalBundledSourceHashes {
            for hash in hashes {
                #expect(hash != kind.formula.sourceHash)
                #expect(hash.count == 64)
            }
        }
    }

    @Test("Raw float selectors from scene files convert without trapping")
    func rawSelectorConversionIsTotal() {
        // Scene decode applies formulaParamValues verbatim, so slot 0 can hold
        // any Float. `Int(Float)` traps on NaN/±inf/|v| > Int.max — the UI must
        // reject those instead of converting (the shader clamps the same slot).
        for primitive in FractalPrimitiveKind.allCases {
            #expect(FractalPrimitiveKind(rawSelector: Float(primitive.selector)) == primitive)
        }
        #expect(FractalPrimitiveKind(rawSelector: 0.4) == .sphere)   // rounds down
        #expect(FractalPrimitiveKind(rawSelector: 1e30) == nil)      // > Int.max: trapped before
        #expect(FractalPrimitiveKind(rawSelector: -1e30) == nil)
        #expect(FractalPrimitiveKind(rawSelector: .nan) == nil)      // trapped before
        #expect(FractalPrimitiveKind(rawSelector: .infinity) == nil)
        #expect(FractalPrimitiveKind(rawSelector: -.infinity) == nil)
        #expect(FractalPrimitiveKind(rawSelector: -1) == nil)
        #expect(FractalPrimitiveKind(rawSelector: 13) == nil)        // past the library
    }

    @Test("Construction primitive selectors remain stable as the library grows")
    func bundledPrimitiveSelectorsRemainStable() {
        let expected: [(FractalPrimitiveKind, Int)] = [
            (.sphere, 0),
            (.box, 1),
            (.torus, 2),
            (.octahedron, 3),
            (.mandelboxSeed, 4),
            (.capsule, 5),
            (.cylinder, 6),
            (.cone, 7),
            (.hexagonalPrism, 8),
            (.pyramid, 9),
            (.tetrahedron, 10),
            (.icosahedron, 11),
            (.dodecahedron, 12)
        ]

        #expect(Set(expected.map { $0.1 }).count == expected.count)
        #expect(FractalPrimitiveKind.analyticCases.count == 12)
        #expect(!FractalPrimitiveKind.analyticCases.contains(.mandelboxSeed))

        for (primitive, selector) in expected {
            #expect(primitive.selector == selector)
            #expect(FractalPrimitiveKind(selector: selector) == primitive)
            #expect(Int(FormulaCatalog.getParam(
                primitive.bundledFormulaParams,
                index: 0
            ).rounded()) == selector)
        }
    }

    @Test("At least one embedded-formula example exists to exercise the compiler")
    func haveEmbeddedFormulas() throws {
        let formulas = try Self.collectEmbeddedFormulas()
        func hasStandaloneFile(_ kind: EffectKind) -> Bool {
            formulas.contains {
                $0.source.hasSuffix(".threshfx") && $0.formula.effectKind == kind
            }
        }
        #expect(!formulas.isEmpty, "no embedded-formula example assets found under \(Self.examplesDir.path)")
        #expect(hasStandaloneFile(.fractal),
                "no custom-fractal .threshfx example found under \(Self.examplesDir.path)")
        #expect(hasStandaloneFile(.spaceWarp),
                "no custom-space-warp .threshfx example found under \(Self.examplesDir.path)")
        #expect(hasStandaloneFile(.lighting),
                "no custom-lighting .threshfx example found under \(Self.examplesDir.path)")
    }

    @MainActor
    @Test("Bundled Voronoi menu modifier loads from the packaged .threshfx resource")
    func bundledVoronoiMenuResourceLoads() throws {
        let hash = try #require(
            AppModel.bundledVoronoiSpaceWarpSourceHash,
            "the app bundle could not decode the Voronoi space-warp .threshfx"
        )
        #expect(hash == "586ec7bc5db26d4029d8b0ff003e3ddbf1ca845262c87f95d51f51b9d5974218")
        #expect(AppModel.bundledVoronoiSpaceWarpControlProfileSourceHashes.contains(hash))

        let lookalike = EmbeddedFormula(
            kind: .spaceWarp,
            id: AppModel.bundledVoronoiSpaceWarpID,
            name: "Unrecognized Voronoi revision",
            functionStem: "DifferentSource",
            metalSource: """
            FORCE_INLINE float3 customSpaceWarp(float3 p, float s, float a, float b, float c) {
                return p + float3(a, b, c) * s;
            }
            FORCE_INLINE float customSpaceWarpDEScale(float3 p, float s, float a, float b, float c) {
                return 1.0f + abs(s);
            }
            """,
            params: []
        )
        #expect(AppModel.customSpaceWarpControlProfile(for: lookalike) == .generic)
    }

    @Test("A space-warp .threshfx file validates and compiles in the production warp slot")
    func diskSpaceWarpContainerCompiles() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available; skipping space-warp .threshfx compile coverage")
            return
        }

        // Keep this fixture test-owned: it must cross the real file decoder without
        // adding a synthetic effect to the app's shipped Examples catalog.
        let fixture = EmbeddedFormula(
            kind: .spaceWarp,
            id: "test.disk-space-warp",
            name: "Disk Space Warp",
            functionStem: "DiskSpaceWarp",
            metalSource: """
            FORCE_INLINE float3 customSpaceWarp(
                float3 p, float strength, float param1, float param2, float param3
            ) {
                if (strength <= 0.0f) { return p; }
                float frequency = max(abs(param1), 0.01f);
                float phase = frequency * p.y + param3;
                float3 offset = float3(sin(phase), 0.0f, cos(phase));
                return p + offset * (strength * param2);
            }

            FORCE_INLINE float customSpaceWarpDEScale(
                float3 p, float strength, float param1, float param2, float param3
            ) {
                (void)p;
                (void)param3;
                if (strength <= 0.0f) { return 1.0f; }
                return 1.0f + abs(strength * param1 * param2);
            }
            """,
            params: []
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThresholdTests-SpaceWarp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("DiskSpaceWarp.threshfx")
        try EmbeddedFormulaContainer(formula: fixture).encode().write(to: file, options: .atomic)
        #expect(file.pathExtension == "threshfx")

        // This is the same validating disk boundary used by AppModel.openExternalFile.
        let decoded = try EmbeddedFormulaContainer.decode(fromContainerAt: file)
        #expect(decoded.version == EmbeddedFormulaContainer.currentVersion)
        #expect(decoded.formula.effectKind == .spaceWarp)
        #expect(decoded.formula == fixture)

        let compiler = CustomShaderCompiler(device: device)
        let cacheKey = CustomShaderCompiler.combinedHash(
            fractal: nil,
            spaceWarp: decoded.formula
        )
        let library = try await compiler.library(
            forFractal: nil,
            spaceWarp: decoded.formula
        )
        #expect(library.makeFunction(name: "vertexShader") != nil)
        await compiler.evict(combinedHash: cacheKey)
    }

    @Test("Every embedded formula compiles through the production CustomShaderCompiler")
    func embeddedFormulasCompile() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // No Metal device on this host (e.g. headless CI without a GPU) —
            // can't exercise the compiler. Decode coverage still runs in
            // ExampleSceneDecodeTests; skip rather than false-fail.
            Issue.record("No Metal device available; skipping embedded-DE compile coverage")
            return
        }

        let formulas = try Self.collectEmbeddedFormulas()
        let compiler = CustomShaderCompiler(device: device)
        var compiledKeys = Set<String>()

        for (source, formula) in formulas {
            let fractal: EmbeddedFormula?
            let spaceWarp: EmbeddedFormula?
            let lighting: EmbeddedFormula?
            let kind: String
            switch formula.effectKind {
            case .fractal:
                (fractal, spaceWarp, lighting, kind) = (formula, nil, nil, "DE")
            case .spaceWarp:
                (fractal, spaceWarp, lighting, kind) = (nil, formula, nil, "space-warp")
            case .lighting:
                (fractal, spaceWarp, lighting, kind) = (nil, nil, formula, "lighting")
            }
            let cacheKey = CustomShaderCompiler.combinedHash(
                fractal: fractal,
                spaceWarp: spaceWarp,
                lighting: lighting
            )
            guard compiledKeys.insert(cacheKey).inserted else { continue }
            do {
                // Route exactly as Renderer.activateEmbeddedFormula does: each
                // effect occupies its independent compiler slot.
                _ = try await compiler.library(
                    forFractal: fractal,
                    spaceWarp: spaceWarp,
                    lighting: lighting
                )
            } catch {
                // The error carries the exact Metal compiler diagnostic (file:line +
                // message), e.g. an embedded DE using the GLSL-ism `radians()` which
                // MSL does not provide. Surfaced in the test failure / .xcresult.
                Issue.record("Embedded \(kind) '\(formula.name)' from \(source) FAILED to compile: \(error)")
            }

            // This test validates every payload in one process, unlike normal app
            // usage. Do not retain one full MTLLibrary per catalog entry: the
            // production cache API itself is covered elsewhere, and holding the
            // entire catalog needlessly raises peak memory while this test runs.
            await compiler.evict(combinedHash: cacheKey)
        }
    }

    #if os(macOS)
    @Test("macOS viewport installs and detaches a lighting-only library")
    func macViewportLightingActivation() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available; skipping macOS viewport activation coverage")
            return
        }
        guard let lighting = try Self.collectEmbeddedFormulas()
            .map(\.formula)
            .first(where: { $0.effectKind == .lighting }) else {
            Issue.record("No bundled lighting fixture found")
            return
        }

        let box = ViewportCustomShaderBox()
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[VertexAttribute.position.rawValue].format = .float3
        vertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue
        vertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = .float2
        vertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue
        vertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        vertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        box.configureGenericPipelineFactory(
            ViewportCustomGenericPipelineFactory(
                device: device,
                colorPixelFormat: .rgba16Float,
                depthPixelFormat: .depth32Float,
                vertexDescriptor: vertexDescriptor
            )
        )
        let cache = ViewportSpecializedPipelineCache()
        do {
            try await box.activate(nil, lighting: lighting, device: device, cache: cache)
        } catch {
            // GitHub's macOS runners expose an "Apple Paravirtual device" that
            // compiles Metal libraries but cannot build the custom render
            // pipeline — the same limitation that blanks every custom scene in
            // the Quick Look render gate. Treat that as missing GPU coverage
            // rather than a regression; real hardware still fails loudly.
            if device.name.contains("Paravirtual")
                || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
                print("Skipping macOS viewport activation coverage on virtualized GPU: \(error)")
                return
            }
            throw error
        }

        let active = box.snapshot()
        #expect(active.library != nil)
        #expect(active.genericPipeline != nil)
        #expect(active.hash == CustomShaderCompiler.combinedHash(
            fractal: nil,
            spaceWarp: nil,
            lighting: lighting
        ))

        try await box.activate(nil, device: device, cache: cache)
        let detached = box.snapshot()
        #expect(detached.library == nil)
        #expect(detached.hash == nil)
    }

    @Test("Bundled lighting demo materially changes the public material ABI")
    func bundledLightingDemoChangesMaterialOutputs() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available; skipping lighting behavior probe")
            return
        }

        let url = Self.examplesDir
            .appendingPathComponent("Formulas")
            .appendingPathComponent("IridescentRimLighting.threshfx")
        let lighting = try EmbeddedFormulaContainer
            .decode(fromContainerAt: url)
            .formula
        #expect(lighting.effectKind == .lighting)
        let defaultParameterValues = lighting.resolvedParameterValues()
        var authoredParameterValues = defaultParameterValues
        authoredParameterValues[0] = 0.0  // no tint
        authoredParameterValues[1] = 0.0  // no rim emission
        authoredParameterValues[3] = 0.0  // no specular response
        authoredParameterValues[4] = 256.0
        authoredParameterValues[6] = 2.0
        authoredParameterValues[7] = 2.0
        authoredParameterValues[8] = 0.0  // no base emission
        let parameterBanks = defaultParameterValues + authoredParameterValues

        // Execute the external author's real Metal entry point with a tiny
        // one-thread harness. This proves numerical behavior, not merely that
        // the full renderer accepted the source and built a pipeline.
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        #define FORCE_INLINE __attribute__((always_inline)) inline

        struct ThresholdMaterial {
            half3 baseColor;
            half3 specularTint;
            half3 emission;
            float diffuseScale;
            float ambientScale;
            float specularScale;
            float specularPower;
        };

        struct CustomLightingParams {
            float values[16];
        };

        struct ThresholdLightingContext {
            float3 position;
            float3 normal;
            float3 viewDirection;
            float3 spotDirection;
            float3 sunDirection;
            float spotAttenuation;
            float sunDiffuseScale;
            float lightIntensity;
            float hostSpecularPower;
            float animationTime;
            half shadowSpot;
            half shadowSun;
            CustomLightingParams params;
        };

        inline float thresholdLightingParam(ThresholdLightingContext context, uint index)
        {
            return context.params.values[min(index, 15u)];
        }

        \(lighting.metalSource)

        kernel void probeLighting(device float4 *output [[buffer(0)]],
                                  device const CustomLightingParams *parameterBanks [[buffer(1)]],
                                  uint tid [[thread_position_in_grid]])
        {
            if (tid >= 2) return;

            ThresholdLightingContext context;
            context.position = float3(0.0f);
            context.normal = normalize(float3(3.7f, -2.1f, 0.0f));
            context.viewDirection = float3(0.0f, 0.0f, 1.0f);
            context.spotDirection = float3(0.0f, 1.0f, 0.0f);
            context.sunDirection = float3(1.0f, 0.0f, 0.0f);
            context.spotAttenuation = 1.0f;
            context.sunDiffuseScale = 1.0f;
            context.lightIntensity = 1.0f;
            context.hostSpecularPower = 128.0f;
            context.animationTime = 0.0f;
            context.shadowSpot = 1.0h;
            context.shadowSun = 1.0h;
            for (uint i = 0; i < 16; ++i) {
                context.params.values[i] = parameterBanks[tid].values[i];
            }

            ThresholdMaterial host;
            host.baseColor = half3(0.8h, 0.7h, 0.6h);
            host.specularTint = half3(1.0h);
            host.emission = half3(0.0h);
            host.diffuseScale = 1.0f;
            host.ambientScale = 1.0f;
            host.specularScale = 1.0f;
            host.specularPower = context.hostSpecularPower;

            ThresholdMaterial result = Lighting_IridescentRimLighting(context, host);
            uint outputIndex = tid * 4u;
            output[outputIndex + 0u] = float4(float3(result.baseColor), result.diffuseScale);
            output[outputIndex + 1u] = float4(float3(result.specularTint), result.specularScale);
            output[outputIndex + 2u] = float4(float3(result.emission), result.specularPower);
            output[outputIndex + 3u] = float4(result.ambientScale, 0.0f, 0.0f, 0.0f);
        }
        """

        let library = try await device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "probeLighting"),
              let queue = device.makeCommandQueue(),
              let output = device.makeBuffer(
                length: MemoryLayout<SIMD4<Float>>.stride * 8,
                options: .storageModeShared
              ),
              let parameters = device.makeBuffer(
                length: MemoryLayout<Float>.stride * parameterBanks.count,
                options: .storageModeShared
              ),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            Issue.record("Could not create the lighting behavior probe")
            return
        }

        let parameterPointer = parameters.contents().bindMemory(
            to: Float.self,
            capacity: parameterBanks.count
        )
        for (index, value) in parameterBanks.enumerated() {
            parameterPointer[index] = value
        }

        let pipeline = try await device.makeComputePipelineState(function: function)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBuffer(parameters, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: 2, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()
        guard commandBuffer.status == .completed else {
            Issue.record("Lighting behavior probe failed: \(commandBuffer.error?.localizedDescription ?? "unknown GPU error")")
            return
        }

        let pointer = output.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let values = Array(UnsafeBufferPointer(start: pointer, count: 8))
        let base = values[0]
        let specular = values[1]
        let emission = values[2]
        let ambient = values[3]
        let authoredBase = values[4]
        let authoredSpecular = values[5]
        let authoredEmission = values[6]
        let authoredAmbient = values[7]

        let baseDistance = sqrt(
            pow(base.x - 0.8, 2) + pow(base.y - 0.7, 2) + pow(base.z - 0.6, 2)
        )
        let specularDistanceFromWhite = sqrt(
            pow(specular.x - 1.0, 2) + pow(specular.y - 1.0, 2) + pow(specular.z - 1.0, 2)
        )
        #expect(baseDistance > 0.25, "demo must visibly replace the host base colour")
        #expect(max(emission.x, max(emission.y, emission.z)) > 0.5,
                "demo must emit a bright, unmistakable rim")
        #expect(specularDistanceFromWhite > 0.25, "demo must visibly tint host specular")
        #expect(specular.w >= 4.0, "demo specular scale must be obviously stronger")
        #expect(emission.w < 128.0, "demo must broaden the host's specular highlight")
        #expect(base.w < 1.0, "demo must modify diffuse scale")
        #expect(ambient.x < 1.0, "demo must modify ambient scale")

        // Both invocations ran in one dispatch through one compiled pipeline.
        // Their output difference can therefore only come from the live bank.
        #expect(abs(authoredBase.w - 2.0) < 0.01,
                "authored diffuse response must reach the material hook")
        #expect(abs(authoredAmbient.x - 2.0) < 0.01,
                "authored ambient response must reach the material hook")
        #expect(abs(authoredSpecular.w) < 0.01,
                "authored specular strength must reach the material hook")
        #expect(abs(authoredEmission.w - 256.0) < 0.01,
                "authored highlight tightness must reach the material hook")
        #expect(max(authoredEmission.x, max(authoredEmission.y, authoredEmission.z)) < 0.01,
                "zero authored emission must remove the demo glow")
    }
    #endif
}
