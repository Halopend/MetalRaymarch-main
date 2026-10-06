# Shader modules

`../Shaders.metal` assembles these headers in dependency order into one Metal
translation unit. Header fragments avoid duplicate entry points and keep the
static library and runtime custom-formula library on the same implementation.

- `Common`: shared IO, math, DE parameters/transform machinery, color, and ray setup types.
- `Rendering`: proxy vertices, coarse/fine scene marching, lighting, and adaptive phases.
- `Temporal`: history reprojection, its validation probe, and MetalFX motion vectors.
- `Post`: edge detection, post effects, output encoding, RCAS, and MetalFX resolve.
- `Cache`: conservative grid lookup and the shared bake/validation parameter policy.
- `Overlays`: spring navigation and spatial radial menu shaders.

The adaptive entry point owns lane masking, threadgroup initialization, and all
barriers. Phase helpers contain no barriers. Keep edge lanes alive until every
barrier completes; only texture writes are masked. Tile bounds probes use the
geometric tile footprint, including the next tile boundary, by design.

`Scripts/expand_metal_source.py` expands the assembly for custom formulas. It
retains the formula include marker so `CustomShaderCompiler` can insert built-in
and user-defined formulas after the shared ABI and function constants. Any new
module must also appear in `Scripts/metal_embed_inputs.xcfilelist`.

Map iteration macros and the edge radius loop retain their existing arithmetic.
Changing them to typed functions or specialized radius paths requires GPU
profiling and numerical/image comparisons on the target devices.
