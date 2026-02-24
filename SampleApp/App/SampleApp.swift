#if os(visionOS)
import CompositorServices
#endif
import SwiftUI

@main
struct SampleApp: App {
    init() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--benchmark"), index + 1 < args.count {
            let path = args[index + 1]
            BenchmarkState.shared.isBenchmarkMode = true
            let resolvedURL = URL(fileURLWithPath: path)
            BenchmarkState.shared.benchmarkModelPath = resolvedURL
            print("[Benchmark] Mode enabled. Model path: \(resolvedURL.path)")
            print("[Benchmark] File exists: \(FileManager.default.fileExists(atPath: resolvedURL.path))")

            // Look for cameras.json three directories up from the .ply file:
            //   .../model_xxx/point_cloud/iteration_NNNNN/point_cloud.ply
            //                             ^--- .deletingLastPathComponent() x3
            let camerasURL = resolvedURL
                .deletingLastPathComponent()   // iteration_NNNNN/
                .deletingLastPathComponent()   // point_cloud/
                .deletingLastPathComponent()   // model_xxx/
                .appendingPathComponent("cameras.json")

            if FileManager.default.fileExists(atPath: camerasURL.path) {
                do {
                    let cameras = try CameraData.load(from: camerasURL)
                    BenchmarkState.shared.cameras = cameras
                    print("[Benchmark] Loaded \(cameras.count) cameras from \(camerasURL.path)")
                } catch {
                    print("[Benchmark] Warning: could not load cameras.json: \(error)")
                }
            } else {
                print("[Benchmark] No cameras.json found at \(camerasURL.path); timing \(BenchmarkState.shared.benchmarkFrameCount) interactive frames.")
            }

            // --save-images: save each rendered frame as PNG next to the .ply file
            if args.contains("--save-images") {
                let saveURL = resolvedURL.deletingLastPathComponent()
                BenchmarkState.shared.saveImagesURL = saveURL
                print("[Benchmark] Will save rendered images to \(saveURL.path)")
            }

            let frameCount = BenchmarkState.shared.cameras.isEmpty
                ? BenchmarkState.shared.benchmarkFrameCount
                : BenchmarkState.shared.cameras.count
            print("[Benchmark] Will print result after \(frameCount) frames.")
        } else {
            // Drop executable and standard Xcode/macOS args like -NSDocumentRevisionsDebugMode
            if let path = args.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                BenchmarkState.shared.autoLoadModelPath = URL(fileURLWithPath: path)
            }
        }
    }

    var body: some Scene {
        WindowGroup("MetalSplatter Sample App", id: "main") {
            ContentView()
        }

#if os(macOS)
        WindowGroup(for: ModelIdentifier.self) { modelIdentifier in
            MetalKitSceneView(modelIdentifier: modelIdentifier.wrappedValue)
                .navigationTitle(modelIdentifier.wrappedValue?.description ?? "No Model")
        }
#endif // os(macOS)

#if os(visionOS)
        ImmersiveSpace(for: ModelIdentifier.self) { modelIdentifier in
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let modelToLoad = modelIdentifier.wrappedValue
                VisionSceneRenderer.startRendering(layerRenderer, model: modelToLoad)
            }
        }
        .immersionStyle(selection: .constant(immersionStyle), in: immersionStyle)
#endif // os(visionOS)
    }

#if os(visionOS)
    var immersionStyle: ImmersionStyle {
        if #available(visionOS 2, *) {
            .mixed
        } else {
            .full
        }
    }
#endif // os(visionOS)
}
