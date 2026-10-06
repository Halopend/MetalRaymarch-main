// Near-range coarse raymarch (24 steps, max 12 units)
// Compiler unrolls based on FC_FRACTAL_ITERATIONS when defined
FORCE_INLINE float SceneCoarse(float3 rO, float3 rD, float foldingLimit, FractalParams params, int iterations, int fractalType = 0, FormulaParams fp = {}, float maxRayDistance = kMaxRayDistanceDefault, float epsilonScale = 1.0f)
{
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    bool isMandelbulb = (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia ||
                         type == FractalTypeBoxFoldMandelbulb);

    // Mandelbulb DE returns much smaller values near the surface; start closer
    // and use a finer hit threshold to avoid overshooting the thin front face.
    // epsilonScale (=1/effectiveScale) tightens the coarse seed on deep zoom so the
    // fine march starts near the true (sub-unit) surface rather than overshooting it.
    float t = isMandelbulb ? 0.005f : 0.05f;
    float hitThreshold = (isMandelbulb ? 0.005f : 0.02f) * epsilonScale;
    int maxCoarseSteps = isMandelbulb ? 28 : 24;

    // Use MapContinuous with 0.6× iterations for smooth fractional DE.
    // This preserves thin features better than integer iterations/2 because
    // the continuous interpolation avoids the discontinuity that causes
    // the coarse pass to "jump over" fine structures.
    // The 0.6× factor balances speed (fewer iterations) vs. accuracy.
    float coarseIters = float(iterations) * 0.6f;

    for(int j = 0; j < maxCoarseSteps && t <= maxRayDistance; j++)
    {
        float3 p = fma(rD, float3(t), rO);
        float h = MapContinuousUnified(p, params, foldingLimit, coarseIters, fractalType, fp);

        if(UNLIKELY(h < hitThreshold)) return t;

        t += h;
    }

    return kRayMissThreshold + 100.0f;
}
