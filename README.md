This project demonstrates the use of Ray Marching shader technique in VisionOS with Metal rendering pipeline.

The renderer actor is from Xcode's VisionOS template for Metal renderer. There is no scene geometry, everything is done inside fragment shader.

## CPU math benchmark (CSV)

This repo includes a small Swift CLI that benchmarks Mandelbox `Map` variants on CPU and writes a CSV for speed/error comparison.

```zsh
cd FractalBench
swift build -c release

# Near-surface points (found by escape bracketing), write CSV
.build/release/fractalbench --pointSet near-surface --samples 200000 --output fractalbench.csv

# Random points
.build/release/fractalbench --pointSet random --samples 500000 --output fractalbench_random.csv

# Full raymarch benchmark (steps + Map calls per ray)
.build/release/fractalbench --mode ray --rays 200000 --output raybench.csv
```

Shader source: https://www.shadertoy.com/view/ldfGWn#

Result: https://youtu.be/5fP07N_3S_Q
