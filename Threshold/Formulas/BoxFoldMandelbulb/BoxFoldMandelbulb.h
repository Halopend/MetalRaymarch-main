//
//  BoxFoldMandelbulb.h
//  Threshold
//
//  Experimental domain-folded Mandelbulb. This deliberately does NOT insert
//  the fold into the Mandelbulb recurrence. It folds the input domain once,
//  then evaluates the unchanged Mandelbulb distance estimator there:
//
//      d(p) = DE_Mandelbulb(2*clamp(p, -L, L) - p)
//
//  The box fold is piecewise isometric (its Jacobian is diagonal with entries
//  +/-1 away from fold seams), so it needs no distance-scale correction.
//  params[0]=Power, [1]=Bailout, [2]=DerivBias, [3]=FoldLimit,
//  [4]=PolarRotation
//

#ifndef DE_BoxFoldMandelbulb_h
#define DE_BoxFoldMandelbulb_h

FORCE_INLINE float3 BoxFoldMandelbulbDomain(float3 p, float limit) {
    float safeLimit = max(abs(limit), 1e-4f);
    return fma(clamp(p, -safeLimit, safeLimit), float3(2.0f), -p);
}

FORCE_INLINE float DE_BoxFoldMandelbulb(float3 pos, FormulaParams fp, float3x3 rot,
                                        int iterations, int colorIterations,
                                        thread OrbitData& orbit) {
    float3 folded = BoxFoldMandelbulbDomain(pos, fp.params[3]);
    return DE_Mandelbulb(folded, fp, rot, iterations, colorIterations, orbit);
}

FORCE_INLINE float DE_BoxFoldMandelbulb_Dist(float3 pos, FormulaParams fp,
                                             float3x3 rot, int iterations) {
    float3 folded = BoxFoldMandelbulbDomain(pos, fp.params[3]);
    return DE_Mandelbulb_Dist(folded, fp, rot, iterations);
}

#endif /* DE_BoxFoldMandelbulb_h */
