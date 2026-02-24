import Foundation

@MainActor
class BenchmarkState: ObservableObject {
    static let shared = BenchmarkState()

    var isBenchmarkMode = false
    var benchmarkModelPath: URL?
    let benchmarkFrameCount = 100
    var autoLoadModelPath: URL?

    /// Cameras loaded from `cameras.json` alongside the PLY file.
    /// When non-empty, the benchmark renders exactly these camera views instead of
    /// timing arbitrary interactive frames.
    var cameras: [CameraData] = []

    /// Index of the next camera to render in camera-based benchmark mode.
    var currentCameraIndex: Int = 0

    /// When non-nil, each rendered frame is saved as a PNG to this directory.
    var saveImagesURL: URL? = nil

    private init() {}
}
