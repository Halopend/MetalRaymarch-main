# Disabled WIP tests

Moved here (out of the file-system-synchronized `ThresholdTests/` folder) because
they did not compile and were blocking the whole `Scripts/build.sh test` run:

- `WarmStartGateTests.swift` — references `WarmStartGate`, which lives in
  `Rendering/Core/RendererCoreTypes.swift`, deliberately EXCLUDED from the
  `ThresholdMac`/`ThresholdiOS` targets the test bundle links against
  (`PBXFileSystemSynchronizedBuildFileExceptionSet` in project.pbxproj). It also
  assigned a `simd_float4x4` to `FormulaParams.rotMatrix1` (a `matrix_float3x3`).
  To revive: run it against a scheme whose host target includes
  RendererCoreTypes.swift (the visionOS `Threshold` target), and fix the matrix
  assignment.
