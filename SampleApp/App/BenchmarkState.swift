import Foundation

@MainActor
class BenchmarkState: ObservableObject {
    static let shared = BenchmarkState()

    var isBenchmarkMode = false
    var benchmarkModelPath: URL?
    let benchmarkFrameCount = 100
    var autoLoadModelPath: URL?

    private init() {}
}
