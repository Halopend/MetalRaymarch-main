typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 color [[color(0)]];
    float depth [[depth(any)]]; // Output clip-space depth for async timewarp
} FragmentOutput;

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
    float3 modelPos;
} ColorInOut;
