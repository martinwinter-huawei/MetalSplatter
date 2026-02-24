import Foundation
import simd

/// A single camera entry from the vanilla 3DGS `cameras.json` file.
struct CameraData: Codable {
    let id: Int
    let img_name: String
    let width: Int
    let height: Int
    /// Camera centre in world space (3-element vector).
    let position: [Double]
    /// World-to-camera rotation, stored as 3 rows × 3 columns (R_w2c).
    /// Each inner array is one row: rotation[i] = [R[i][0], R[i][1], R[i][2]].
    let rotation: [[Double]]
    /// Focal lengths in pixels.
    let fx: Double
    let fy: Double

    // MARK: - Load helpers

    static func load(from url: URL) throws -> [CameraData] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CameraData].self, from: data)
    }

    // MARK: - Matrix helpers

    /// Returns a Metal-compatible view matrix that transforms world → Metal camera space.
    ///
    /// `cameras.json` stores R_w2c (world-to-OpenCV-camera, rows = camera axes) and the
    /// camera centre in world space.  We convert from OpenCV convention (Y↓, Z forward) to
    /// Metal / OpenGL convention (Y↑, Z backward) by flipping Y and Z via a diag(1,-1,-1)
    /// pre-multiply on the rotation block.
    var viewMatrix: simd_float4x4 {
        // cameras.json `rotation` stores R_cw (camera-to-world) as rows, per the 3DGS/COLMAP
        // convention: R = np.transpose(qvec2rotmat(qvec)) in scene/__init__.py.
        // We need R_w2c = R_cw^T for the view matrix, so we read rows of r as simd columns.
        // rotation[i] = row i of R_cw → column i of R_w2c.
        let r = rotation
        let col0 = SIMD3<Float>(Float(r[0][0]), Float(r[0][1]), Float(r[0][2]))  // row 0 of R_cw = col 0 of R_w2c
        let col1 = SIMD3<Float>(Float(r[1][0]), Float(r[1][1]), Float(r[1][2]))  // row 1 of R_cw = col 1 of R_w2c
        let col2 = SIMD3<Float>(Float(r[2][0]), Float(r[2][1]), Float(r[2][2]))  // row 2 of R_cw = col 2 of R_w2c
        let R_w2c = simd_float3x3(columns: (col0, col1, col2))

        let pos = SIMD3<Float>(Float(position[0]), Float(position[1]), Float(position[2]))
        // Translation: t = -R_w2c * C  (C = camera centre in world space)
        let t = -(R_w2c * pos)

        // [R_w2c | t] in column-major form — world-to-camera in OpenCV convention (Y↓, Z forward)
        var m = simd_float4x4()
        m.columns.0 = SIMD4<Float>(R_w2c.columns.0, 0)
        m.columns.1 = SIMD4<Float>(R_w2c.columns.1, 0)
        m.columns.2 = SIMD4<Float>(R_w2c.columns.2, 0)
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)

        // Convert OpenCV (Y↓, Z forward) → Metal (Y↑, Z backward) so that the
        // right-hand projection matrix maps visible geometry to positive clip-space Z.
        // Equivalent to: M_metal = diag(1,-1,-1,1) * M_opencv
        m.columns.0.y = -m.columns.0.y
        m.columns.0.z = -m.columns.0.z
        m.columns.1.y = -m.columns.1.y
        m.columns.1.z = -m.columns.1.z
        m.columns.2.y = -m.columns.2.y
        m.columns.2.z = -m.columns.2.z
        m.columns.3.y = -m.columns.3.y
        m.columns.3.z = -m.columns.3.z

        return m
    }

    /// Returns a Metal-compatible right-handed perspective projection matrix
    /// for the given render-target aspect ratio, using this camera's focal lengths.
    ///
    /// - Parameter aspectRatio: drawableWidth / drawableHeight of the render target.
    func projectionMatrix(aspectRatio: Float, nearZ: Float = 0.01, farZ: Float = 100.0) -> simd_float4x4 {
        // Vertical FOV from focal length and sensor height.
        let fovY = 2.0 * atan(Float(height) / (2.0 * Float(fy)))
        return matrix_perspective_right_hand(fovyRadians: fovY,
                                             aspectRatio: aspectRatio,
                                             nearZ: nearZ,
                                             farZ: farZ)
    }
}
