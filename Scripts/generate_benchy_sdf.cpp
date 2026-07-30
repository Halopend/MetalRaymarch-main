// Bake a binary STL into Threshold's canonical Float16 signed-distance volume.
//
// Usage:
//   clang++ -std=c++20 -O3 Scripts/generate_benchy_sdf.cpp -o /tmp/benchy-sdf
//   /tmp/benchy-sdf input.stl Threshold/Resources/Benchy.sdfbin

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr int kDim = 96;
constexpr std::array<float, 3> kGridMin{-1.08f, -0.08f, -0.60f};
constexpr std::array<float, 3> kGridMax{ 1.08f,  1.68f,  0.60f};

struct Vec3 {
    float x = 0, y = 0, z = 0;
    float& operator[](int i) { return (&x)[i]; }
    float operator[](int i) const { return (&x)[i]; }
};

Vec3 operator+(Vec3 a, Vec3 b) { return {a.x+b.x, a.y+b.y, a.z+b.z}; }
Vec3 operator-(Vec3 a, Vec3 b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
Vec3 operator*(Vec3 a, float s) { return {a.x*s, a.y*s, a.z*s}; }
Vec3 operator/(Vec3 a, float s) { return a * (1.0f/s); }
float dot(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
Vec3 cross(Vec3 a, Vec3 b) {
    return {a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x};
}
float lengthSquared(Vec3 v) { return dot(v, v); }
Vec3 min(Vec3 a, Vec3 b) {
    return {std::min(a.x,b.x), std::min(a.y,b.y), std::min(a.z,b.z)};
}
Vec3 max(Vec3 a, Vec3 b) {
    return {std::max(a.x,b.x), std::max(a.y,b.y), std::max(a.z,b.z)};
}

struct Triangle {
    Vec3 a, b, c;
    Vec3 lo, hi, centroid;
};

struct Node {
    Vec3 lo, hi;
    int left = -1, right = -1;
    int start = 0, count = 0;
    bool leaf() const { return left < 0; }
};

float pointBoxDistanceSquared(Vec3 p, Vec3 lo, Vec3 hi) {
    float result = 0;
    for (int axis = 0; axis < 3; ++axis) {
        float delta = p[axis] < lo[axis] ? lo[axis] - p[axis]
                    : p[axis] > hi[axis] ? p[axis] - hi[axis] : 0;
        result += delta * delta;
    }
    return result;
}

float pointTriangleDistanceSquared(Vec3 p, const Triangle& triangle) {
    Vec3 a = triangle.a, b = triangle.b, c = triangle.c;
    Vec3 ab = b-a, ac = c-a, ap = p-a;
    float d1 = dot(ab,ap), d2 = dot(ac,ap);
    if (d1 <= 0 && d2 <= 0) return lengthSquared(ap);
    Vec3 bp = p-b;
    float d3 = dot(ab,bp), d4 = dot(ac,bp);
    if (d3 >= 0 && d4 <= d3) return lengthSquared(bp);
    float vc = d1*d4-d3*d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0) {
        float v = d1/(d1-d3);
        return lengthSquared(p-(a+ab*v));
    }
    Vec3 cp = p-c;
    float d5 = dot(ab,cp), d6 = dot(ac,cp);
    if (d6 >= 0 && d5 <= d6) return lengthSquared(cp);
    float vb = d5*d2-d1*d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0) {
        float w = d2/(d2-d6);
        return lengthSquared(p-(a+ac*w));
    }
    float va = d3*d6-d5*d4;
    if (va <= 0 && (d4-d3) >= 0 && (d5-d6) >= 0) {
        Vec3 bc = c-b;
        float w = (d4-d3)/((d4-d3)+(d5-d6));
        return lengthSquared(p-(b+bc*w));
    }
    float denom = 1.0f/(va+vb+vc);
    float v = vb*denom, w = vc*denom;
    return lengthSquared(p-(a+ab*v+ac*w));
}

bool rayBox(Vec3 origin, Vec3 direction, Vec3 lo, Vec3 hi) {
    float nearT = 0, farT = std::numeric_limits<float>::infinity();
    for (int axis = 0; axis < 3; ++axis) {
        float inverse = 1.0f / direction[axis];
        float t0 = (lo[axis] - origin[axis]) * inverse;
        float t1 = (hi[axis] - origin[axis]) * inverse;
        if (t0 > t1) std::swap(t0, t1);
        nearT = std::max(nearT, t0);
        farT = std::min(farT, t1);
        if (nearT > farT) return false;
    }
    return farT > 1e-6f;
}

bool rayTriangle(Vec3 origin, Vec3 direction, const Triangle& triangle) {
    Vec3 edge1 = triangle.b-triangle.a;
    Vec3 edge2 = triangle.c-triangle.a;
    Vec3 h = cross(direction, edge2);
    float determinant = dot(edge1, h);
    if (std::abs(determinant) < 1e-8f) return false;
    float inverse = 1.0f/determinant;
    Vec3 s = origin-triangle.a;
    float u = inverse*dot(s,h);
    if (u < 0 || u > 1) return false;
    Vec3 q = cross(s,edge1);
    float v = inverse*dot(direction,q);
    if (v < 0 || u+v > 1) return false;
    return inverse*dot(edge2,q) > 1e-6f;
}

class TriangleBVH {
public:
    explicit TriangleBVH(std::vector<Triangle> triangles)
        : triangles_(std::move(triangles)), indices_(triangles_.size()) {
        std::iota(indices_.begin(), indices_.end(), 0);
        nodes_.reserve(triangles_.size()/2);
        build(0, static_cast<int>(indices_.size()));
    }

    float distance(Vec3 point) const {
        float best = std::numeric_limits<float>::infinity();
        std::array<int, 128> stack{};
        int stackSize = 1;
        stack[0] = 0;
        while (stackSize) {
            int nodeIndex = stack[--stackSize];
            const Node& node = nodes_[nodeIndex];
            if (pointBoxDistanceSquared(point,node.lo,node.hi) >= best) continue;
            if (node.leaf()) {
                for (int i = 0; i < node.count; ++i) {
                    best = std::min(
                        best,
                        pointTriangleDistanceSquared(
                            point,
                            triangles_[indices_[node.start+i]]
                        )
                    );
                }
            } else {
                // Near child first improves pruning while retaining a tiny stack.
                float dl = pointBoxDistanceSquared(
                    point, nodes_[node.left].lo, nodes_[node.left].hi
                );
                float dr = pointBoxDistanceSquared(
                    point, nodes_[node.right].lo, nodes_[node.right].hi
                );
                int nearChild = dl < dr ? node.left : node.right;
                int farChild = dl < dr ? node.right : node.left;
                stack[stackSize++] = farChild;
                stack[stackSize++] = nearChild;
            }
        }
        return std::sqrt(best);
    }

    bool inside(Vec3 point) const {
        // A non-axis ray avoids systematic coincidences with the voxel lattice
        // and STL face diagonals. Parity is orientation-independent.
        Vec3 direction{1.0f, 0.37139067f, 0.52911311f};
        direction = direction / std::sqrt(lengthSquared(direction));
        int intersections = 0;
        std::array<int, 128> stack{};
        int stackSize = 1;
        stack[0] = 0;
        while (stackSize) {
            const Node& node = nodes_[stack[--stackSize]];
            if (!rayBox(point,direction,node.lo,node.hi)) continue;
            if (node.leaf()) {
                for (int i = 0; i < node.count; ++i) {
                    intersections += rayTriangle(
                        point, direction, triangles_[indices_[node.start+i]]
                    );
                }
            } else {
                stack[stackSize++] = node.left;
                stack[stackSize++] = node.right;
            }
        }
        return (intersections & 1) != 0;
    }

private:
    int build(int start, int count) {
        Vec3 infinity{std::numeric_limits<float>::infinity(),
                      std::numeric_limits<float>::infinity(),
                      std::numeric_limits<float>::infinity()};
        Vec3 lo = infinity, hi = infinity * -1.0f;
        Vec3 centroidLo = infinity, centroidHi = infinity * -1.0f;
        for (int i = start; i < start+count; ++i) {
            const Triangle& triangle = triangles_[indices_[i]];
            lo = min(lo,triangle.lo); hi = max(hi,triangle.hi);
            centroidLo = min(centroidLo,triangle.centroid);
            centroidHi = max(centroidHi,triangle.centroid);
        }
        int nodeIndex = static_cast<int>(nodes_.size());
        nodes_.push_back(Node{lo,hi,-1,-1,start,count});
        if (count <= 8) return nodeIndex;

        Vec3 extent = centroidHi-centroidLo;
        int axis = extent.y > extent.x ? 1 : 0;
        if (extent.z > extent[axis]) axis = 2;
        int middle = start+count/2;
        std::nth_element(
            indices_.begin()+start,
            indices_.begin()+middle,
            indices_.begin()+start+count,
            [&](int lhs, int rhs) {
                return triangles_[lhs].centroid[axis] < triangles_[rhs].centroid[axis];
            }
        );
        int left = build(start,middle-start);
        int right = build(middle,start+count-middle);
        nodes_[nodeIndex].left = left;
        nodes_[nodeIndex].right = right;
        nodes_[nodeIndex].count = 0;
        return nodeIndex;
    }

    std::vector<Triangle> triangles_;
    std::vector<int> indices_;
    std::vector<Node> nodes_;
};

uint32_t readU32(std::istream& stream) {
    std::array<unsigned char,4> bytes{};
    stream.read(reinterpret_cast<char*>(bytes.data()),4);
    return uint32_t(bytes[0]) | (uint32_t(bytes[1])<<8)
         | (uint32_t(bytes[2])<<16) | (uint32_t(bytes[3])<<24);
}

float readF32(std::istream& stream) {
    uint32_t bits = readU32(stream);
    return std::bit_cast<float>(bits);
}

std::vector<Triangle> readSTL(const std::string& path) {
    std::ifstream input(path,std::ios::binary);
    if (!input) throw std::runtime_error("could not open STL");
    input.seekg(80);
    uint32_t count = readU32(input);
    std::vector<std::array<Vec3,3>> raw;
    raw.reserve(count);
    Vec3 lo{INFINITY,INFINITY,INFINITY}, hi{-INFINITY,-INFINITY,-INFINITY};
    for (uint32_t i = 0; i < count; ++i) {
        for (int n = 0; n < 3; ++n) (void)readF32(input); // normal
        std::array<Vec3,3> vertices;
        for (Vec3& vertex : vertices) {
            vertex = {readF32(input),readF32(input),readF32(input)};
            lo = min(lo,vertex); hi = max(hi,vertex);
        }
        input.ignore(2);
        raw.push_back(vertices);
    }
    if (!input) throw std::runtime_error("truncated STL");

    float scale = 2.0f/(hi.x-lo.x);
    float centerX = 0.5f*(lo.x+hi.x);
    float centerY = 0.5f*(lo.y+hi.y);
    auto canonical = [&](Vec3 v) {
        // STL X/Y/Z-up -> Threshold X/Z/Y-up.
        return Vec3{(v.x-centerX)*scale, (v.z-lo.z)*scale, (v.y-centerY)*scale};
    };

    std::vector<Triangle> triangles;
    triangles.reserve(raw.size());
    for (const auto& source : raw) {
        Triangle triangle;
        triangle.a = canonical(source[0]);
        triangle.b = canonical(source[1]);
        triangle.c = canonical(source[2]);
        if (lengthSquared(cross(triangle.b-triangle.a,triangle.c-triangle.a)) < 1e-16f) {
            continue;
        }
        triangle.lo = min(triangle.a,min(triangle.b,triangle.c));
        triangle.hi = max(triangle.a,max(triangle.b,triangle.c));
        triangle.centroid = (triangle.a+triangle.b+triangle.c)/3.0f;
        triangles.push_back(triangle);
    }
    std::cerr << "Loaded " << triangles.size() << " valid triangles\n";
    return triangles;
}

uint16_t floatToHalf(float value) {
    uint32_t bits = std::bit_cast<uint32_t>(value);
    uint32_t sign = (bits >> 16) & 0x8000;
    int exponent = int((bits >> 23) & 0xff) - 127 + 15;
    uint32_t mantissa = bits & 0x7fffff;
    if (exponent <= 0) {
        if (exponent < -10) return static_cast<uint16_t>(sign);
        mantissa = (mantissa | 0x800000) >> (1-exponent);
        return static_cast<uint16_t>(sign | ((mantissa+0x1000)>>13));
    }
    if (exponent >= 31) return static_cast<uint16_t>(sign | 0x7c00);
    return static_cast<uint16_t>(
        sign | (uint32_t(exponent)<<10) | ((mantissa+0x1000)>>13)
    );
}

void writeU32(std::array<char,64>& header, int offset, uint32_t value) {
    header[offset+0] = char(value);
    header[offset+1] = char(value>>8);
    header[offset+2] = char(value>>16);
    header[offset+3] = char(value>>24);
}

void writeF32(std::array<char,64>& header, int offset, float value) {
    writeU32(header,offset,std::bit_cast<uint32_t>(value));
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: generate_benchy_sdf input.stl output.sdfbin\n";
        return 2;
    }
    try {
        TriangleBVH bvh(readSTL(argv[1]));
        const size_t voxelCount = size_t(kDim)*kDim*kDim;
        std::vector<uint16_t> voxels(voxelCount);
        std::atomic<size_t> insideCount{0};
        std::atomic<int> nextZ{0};
        int workerCount = std::max(1u,std::thread::hardware_concurrency());
        std::vector<std::thread> workers;
        for (int worker = 0; worker < workerCount; ++worker) {
            workers.emplace_back([&] {
                while (true) {
                    int z = nextZ.fetch_add(1);
                    if (z >= kDim) break;
                    for (int y = 0; y < kDim; ++y) {
                        for (int x = 0; x < kDim; ++x) {
                            Vec3 p{
                                kGridMin[0] + (x+0.5f)*(kGridMax[0]-kGridMin[0])/kDim,
                                kGridMin[1] + (y+0.5f)*(kGridMax[1]-kGridMin[1])/kDim,
                                kGridMin[2] + (z+0.5f)*(kGridMax[2]-kGridMin[2])/kDim
                            };
                            float distance = bvh.distance(p);
                            if (bvh.inside(p)) {
                                distance = -distance;
                                insideCount.fetch_add(1,std::memory_order_relaxed);
                            }
                            voxels[(size_t(z)*kDim+y)*kDim+x] = floatToHalf(distance);
                        }
                    }
                    std::cerr << "\rBaked slice " << (z+1) << "/" << kDim << std::flush;
                }
            });
        }
        for (auto& worker : workers) worker.join();
        std::cerr << "\nInside voxels: " << insideCount.load() << "/" << voxelCount << "\n";

        std::array<char,64> header{};
        std::memcpy(header.data(),"THRSDF1",7);
        writeU32(header,8,kDim);
        writeU32(header,12,1); // format 1 = little-endian IEEE Float16
        for (int i = 0; i < 3; ++i) writeF32(header,16+i*4,kGridMin[i]);
        for (int i = 0; i < 3; ++i) writeF32(header,28+i*4,kGridMax[i]);
        writeU32(header,40,static_cast<uint32_t>(voxelCount*2));

        std::ofstream output(argv[2],std::ios::binary);
        if (!output) throw std::runtime_error("could not open output");
        output.write(header.data(),header.size());
        output.write(
            reinterpret_cast<const char*>(voxels.data()),
            static_cast<std::streamsize>(voxels.size()*sizeof(uint16_t))
        );
        if (!output) throw std::runtime_error("failed while writing output");
        std::cerr << "Wrote " << argv[2] << " (" << (header.size()+voxels.size()*2)
                  << " bytes)\n";
    } catch (const std::exception& error) {
        std::cerr << "error: " << error.what() << "\n";
        return 1;
    }
    return 0;
}
