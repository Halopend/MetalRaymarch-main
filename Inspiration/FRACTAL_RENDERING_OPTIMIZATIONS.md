# Fractal Rendering Optimization Research

This document collects the fastest known techniques for fractal rendering, compiled for reference during MetalRaymarch optimization work.

## Reference Projects

### DeepDrill
https://github.com/dirkwhoffmann/DeepDrill

State-of-the-art fractal renderer combining perturbation theory and series approximation. Makes zoom depths previously requiring weeks now computable in minutes.

## Fastest Known Techniques

### Distance Estimation (DE) with Analytical Derivatives

The cornerstone of efficient 3D fractal rendering. DE calculates the minimum distance from the current ray position to the fractal surface, allowing rays to safely advance in large steps.

For the Mandelbulb (power-8 formula), the most efficient implementation uses the scalar analytical derivative approach:

```
DE = 0.5 * ln(r) * r / dr
where dr_n = 8|f_{n-1}(c)|^7 * dr_{n-1} + 1
```

The scalar method outperforms the Jacobian matrix approach because it avoids singularities along transformation axes and provides a 4x speedup compared to numerical four-point gradient approximations.

For the Mandlebox, the scalar analytical DE also works exceptionally well, requiring only one evaluation per ray step instead of four. Optimal performance occurs with 5-6 iterations per fractal evaluation.

### Perturbation Theory + Series Approximation

Provides orders of magnitude speedup for deep zooming. The algorithm:

1. Computes a reference orbit with full arbitrary precision at one center point
2. Uses native (fast) precision for neighboring pixels as perturbations of this orbit
3. For ultra-deep zooms, precomputes series approximation coefficients

This reduces render times from weeks to minutes while maintaining accuracy at zoom levels impossible with native floating-point.

### GPU Acceleration with Progressive Refinement

Compute shaders split fractal computation across parallel threads. The critical optimization is progressive refinement: dividing the screen into chunks (typically 32x32 pixels) and processing incrementally across frames. This ensures constant frame rates even when iteration counts increase at deep zoom levels.

The floating-point precision limit on GPUs is approximately 14x zoom depth with FP64 before visual artifacts appear. Perturbation theory overcomes this limitation.

### Smooth Iteration Count / Normalized Iteration Count

Eliminates banding artifacts in escape-time coloring:

```
nu(z) = n + 1 - log(log|z_n|) / log(p)
```

where p is the power parameter. Provides smooth color gradients without expensive additional computation.

### Acceleration Structure Caching

Research implementation achieved up to 2x rendering speedup by caching distance estimation spheres. Primary rays build the structure in first pass, then secondary rays reuse precomputed distances without recalculating expensive DE functions.

### Adaptive Iteration Scaling

Rather than fixed maximum iterations, use logarithmic scaling based on current zoom level. Iteration count automatically increases as needed without wasting computation at shallow zoom levels.

### CPU-Level SIMD Optimization

Single Instruction Multiple Data vectorization processes 4-8 pixels simultaneously using masked operations. When pixels escape at different iteration counts, SIMD masking enables processing only non-diverged pixels, achieving 2x+ single-core speedups.

## Derivative Methods Comparison

| Method | Relative Speed | Accuracy | Notes |
|--------|----------------|----------|-------|
| Potential gradient (Quilez) | 1.1x | Very good | 4-point numerical approximation |
| Escape length gradient (Makin/Buddhi) | 1.1x | Good | Less sensitive to epsilon selection |
| Scalar analytical | 4.1x | Good | Mandelbulb/Mandlebox standard |
| Jacobian analytical | 4.1x | Excellent | Singular point issues on axes |

## Mandelbulb-Specific Optimizations

Requires converting to spherical coordinates each iteration:

```glsl
theta = acos(z.z/r)
phi = atan(z.y, z.x)
dr = pow(r, Power-1.0) * Power * dr + 1.0
zr = pow(r, Power)
theta = theta * Power
phi = phi * Power
z = zr * vec3(sin(theta)*cos(phi), sin(phi)*sin(theta), cos(theta))
z += pos
```

Using scalar derivative directly on running magnitude avoids triplex multiplication definition.

## Mandlebox-Specific Optimizations

Uses folding and scaling operations:

```glsl
if (length < min_radius^2) multiply by (fixed_radius^2)/(min_radius^2)
else if (length < fixed_radius^2) multiply by (fixed_radius^2)/length
multiply by mandelbox_scale and add position
```

The modulo operator enables complex folding patterns without expensive recursive iteration.

## Real-Time Implementation Strategy

For maximum performance (in order of implementation):

1. **Foundation**: GPU compute shader with FP64 and simple distance estimation
2. **Next level**: Scalar analytical derivatives for Mandelbulb/Mandlebox
3. **Interactivity**: Progressive refinement with adaptive iteration counts
4. **Deep zoom**: Perturbation theory with arbitrary-precision reference
5. **Ultra-depth**: Series approximation for pre-computed coefficient acceleration

## Key Reference Sources

1. **Distance Estimated 3D Fractals (Part V): The Mandelbulb - Different DE Approximations**
   - Comprehensive comparison of scalar derivatives vs. Jacobian vs. numerical approximations
   - Exact performance metrics (4.1x speedup for analytical vs 1.1x for numerical)

2. **Distance Estimated 3D Fractals (Part I) - Syntopia (Hvidtfeldt)**
   - Foundational ray marching + distance estimation framework

3. **Distance Estimated 3D Fractals (VI): The Mandelbox**
   - Scalar derivative approach specific to Mandlebox folding operations

4. **Notes on Mandelbrot Set (Draft)**
   - Complete technical reference on perturbation theory + series approximation
   - Glitch detection (Pauldelbrot criterion)

5. **Series Approximation and the Mandelbrot set - philthompson.me**
   - Practical series approximation guide for polynomial approximation

6. **Implementing Series Approximation/Perturbation Theory for WebGL2**
   - Working code examples for GPU rendering

7. **Distance Estimated 3D Fractals (VII): Dual Numbers - Syntopia**
   - Automatic derivative computation without manual tracking

8. **Plotting Algorithms for the Mandelbrot Set - Wikipedia**
   - Comprehensive overview of escape time algorithms and bailout conditions

## State-of-the-Art Tools

- **DeepDrill**: Perturbation theory + series approximation
- **Mandelbulber2**: Comprehensive DE methods
- **Mandelbulb3D**: DE methods implementation
- **Ultra Fractal**: Built-in perturbation calculations
