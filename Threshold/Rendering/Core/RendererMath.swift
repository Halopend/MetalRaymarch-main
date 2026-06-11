import simd

/// Convert a unit quaternion (x, y, z, w) to a 4×4 rotation matrix.
func matrix4x4_from_quaternion(_ q: simd_quatf) -> matrix_float4x4 {
    let v = q.vector   // (x, y, z, w)
    let x = v.x, y = v.y, z = v.z, w = v.w
    let xx = x * x, yy = y * y, zz = z * z
    let xy = x * y, xz = x * z, yz = y * z
    let wx = w * x, wy = w * y, wz = w * z
    return matrix_float4x4(columns: (
        vector_float4(1 - 2*(yy + zz), 2*(xy + wz),     2*(xz - wy),     0),
        vector_float4(2*(xy - wz),     1 - 2*(xx + zz),  2*(yz + wx),     0),
        vector_float4(2*(xz + wy),     2*(yz - wx),      1 - 2*(xx + yy), 0),
        vector_float4(0, 0, 0, 1)
    ))
}

func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x
    let y = unitAxis.y
    let z = unitAxis.z
    return matrix_float4x4.init(columns: (vector_float4(ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                                          vector_float4(x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0),
                                          vector_float4(x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0),
                                          vector_float4(0, 0, 0, 1)))
}

func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
    return matrix_float4x4.init(columns: (vector_float4(1, 0, 0, 0),
                                          vector_float4(0, 1, 0, 0),
                                          vector_float4(0, 0, 1, 0),
                                          vector_float4(translationX, translationY, translationZ, 1)))
}

func matrix4x4_scale(_ scaleX: Float, _ scaleY: Float, _ scaleZ: Float) -> matrix_float4x4 {
    return matrix_float4x4.init(columns: (vector_float4(scaleX, 0, 0, 0),
                                          vector_float4(0, scaleY, 0, 0),
                                          vector_float4(0, 0, scaleZ, 0),
                                          vector_float4(0, 0, 0, 1)))
}
