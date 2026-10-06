constant uint ADAPTIVE_TILE_SIZE = 8;
constant uint ADAPTIVE_SUPERTILE_SIZE = 32;
constant uint ADAPTIVE_SUPERTILE_TILE_COUNT = ADAPTIVE_SUPERTILE_SIZE / ADAPTIVE_TILE_SIZE;

struct AdaptiveRayContext {
    float2 pixelCenter;
    float3 cameraPos;
    float3 direction;
    float3 origin;
    float3 marchDirection;
    int iterations;
    int maxSteps;
};

struct AdaptiveReprojectionResult {
    float startT;
    float depth;
    bool valid;
    int packetLayer;
};

struct AdaptiveTileCullResult {
    float startT;
    int isEmpty;
};
