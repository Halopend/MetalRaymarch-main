#ifndef PseudoKleinian_h
#define PseudoKleinian_h
#include "../FractalFormulaCommon.h"

FORCE_INLINE float DE_PseudoKleinian(float3 pos, FormulaParams fp, float3x3 rotMatrix, int iterations, int colorIterations, thread OrbitData& orbit) {
    float3 p = pos;
    float scale = 1.0f;
    float trap = 1e20f;
    int trapIt = 0;
    
    float maxR2 = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 gap = float3(fp.params[4], fp.params[5], fp.params[6]);
    float pScale = fp.params[7];
    float3 fold = float3(fp.params[8], fp.params[9], fp.params[10]);
    float boxLimit = fp.params[11];
    float3 cSize = float3(fp.params[13], fp.params[14], fp.params[15]);

    float3 c = p;
    
    int it = 0;
    for (int i = 0; i < iterations; i++) {
        float3 t = p;
        
        float r2 = dot(t - offset, t - offset);
        if (r2 < maxR2) {
            float factor = maxR2 / max(r2, 1e-6f);
            t = (t - offset) * factor + offset;
            scale *= factor;
        }

        if (t.x < fold.x) t.x = 2.0f * fold.x - t.x;
        if (t.y < fold.y) t.y = 2.0f * fold.y - t.y;
        if (t.z < fold.z) t.z = 2.0f * fold.z - t.z;

        t = t * pScale + c;
        scale = scale * pScale;
        
        if (t.x > boxLimit) t.x = 2.0f * boxLimit - t.x;
        else if (t.x < -boxLimit) t.x = -2.0f * boxLimit - t.x;
        
        if (t.y > boxLimit) t.y = 2.0f * boxLimit - t.y;
        else if (t.y < -boxLimit) t.y = -2.0f * boxLimit - t.y;
        
        if (t.z > boxLimit) t.z = 2.0f * boxLimit - t.z;
        else if (t.z < -boxLimit) t.z = -2.0f * boxLimit - t.z;
        
        t.x = max(abs(t.x) - gap.x, 0.0f) * sign(t.x);
        t.y = max(abs(t.y) - gap.y, 0.0f) * sign(t.y);
        t.z = max(abs(t.z) - gap.z, 0.0f) * sign(t.z);

        t = rotMatrix * t;
        p = t;
        it++;

        if (i < colorIterations) {
            float m = dot(p, p);
            if (m < trap) {
                trap = m;
                trapIt = i;
                orbit.trapPosition = p;
            }
        }
        
        if (dot(p, p) > 256.0f) break;
    }
    
    float3 pb = abs(p) - cSize;
    float dist = (length(max(pb, 0.0f)) + min(max(pb.x, max(pb.y, pb.z)), 0.0f)) / max(abs(scale), 1e-6f);

    orbit.trap = trap;
    orbit.trapIteration = trapIt;
    orbit.finalP = p;
    orbit.iterationsUsed = it;

    return dist;
}

FORCE_INLINE float DE_PseudoKleinian_Dist(float3 pos, FormulaParams fp, float3x3 rotMatrix, int iterations) {
    float3 p = pos;
    float scale = 1.0f;
    
    float maxR2 = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 gap = float3(fp.params[4], fp.params[5], fp.params[6]);
    float pScale = fp.params[7];
    float3 fold = float3(fp.params[8], fp.params[9], fp.params[10]);
    float boxLimit = fp.params[11];
    float3 cSize = float3(fp.params[13], fp.params[14], fp.params[15]);

    float3 c = p;
    
    for (int i = 0; i < iterations; i++) {
        float3 t = p;
        
        float r2 = dot(t - offset, t - offset);
        if (r2 < maxR2) {
            float factor = maxR2 / max(r2, 1e-6f);
            t = (t - offset) * factor + offset;
            scale *= factor;
        }

        if (t.x < fold.x) t.x = 2.0f * fold.x - t.x;
        if (t.y < fold.y) t.y = 2.0f * fold.y - t.y;
        if (t.z < fold.z) t.z = 2.0f * fold.z - t.z;

        t = t * pScale + c;
        scale = scale * pScale;
        
        if (t.x > boxLimit) t.x = 2.0f * boxLimit - t.x;
        else if (t.x < -boxLimit) t.x = -2.0f * boxLimit - t.x;
        
        if (t.y > boxLimit) t.y = 2.0f * boxLimit - t.y;
        else if (t.y < -boxLimit) t.y = -2.0f * boxLimit - t.y;
        
        if (t.z > boxLimit) t.z = 2.0f * boxLimit - t.z;
        else if (t.z < -boxLimit) t.z = -2.0f * boxLimit - t.z;
        
        t.x = max(abs(t.x) - gap.x, 0.0f) * sign(t.x);
        t.y = max(abs(t.y) - gap.y, 0.0f) * sign(t.y);
        t.z = max(abs(t.z) - gap.z, 0.0f) * sign(t.z);

        t = rotMatrix * t;
        p = t;

        if (dot(p, p) > 256.0f) break;
    }
    
    float3 pb = abs(p) - cSize;
    float dist = (length(max(pb, 0.0f)) + min(max(pb.x, max(pb.y, pb.z)), 0.0f)) / max(abs(scale), 1e-6f);

    return dist;
}

#endif /* PseudoKleinian_h */
