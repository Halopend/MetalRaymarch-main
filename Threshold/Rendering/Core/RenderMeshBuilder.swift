import Metal
import MetalKit
import ModelIO

enum RenderMeshBuilder {
    enum BuildError: Error {
        case badVertexDescriptor
    }

    static func makeVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()

        descriptor.attributes[VertexAttribute.position.rawValue].format = .float3
        descriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        descriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        descriptor.attributes[VertexAttribute.texcoord.rawValue].format = .float2
        descriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        descriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        descriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        descriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        descriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = .perVertex

        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = .perVertex

        return descriptor
    }

    static func makeEllipsoid(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mesh = MDLMesh.newEllipsoid(
            withRadii: SIMD3<Float>(repeating: 100),
            radialSegments: 64,
            verticalSegments: 32,
            geometryType: .triangles,
            inwardNormals: false,
            hemisphere: false,
            allocator: allocator
        )

        let modelIODescriptor = MTKModelIOVertexDescriptorFromMetal(vertexDescriptor)
        guard let attributes = modelIODescriptor.attributes as? [MDLVertexAttribute] else {
            throw BuildError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate
        mesh.vertexDescriptor = modelIODescriptor

        return try MTKMesh(mesh: mesh, device: device)
    }
}
