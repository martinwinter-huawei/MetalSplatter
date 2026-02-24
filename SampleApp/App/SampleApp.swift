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
            BenchmarkState.shared.benchmarkModelPath = URL(fileURLWithPath: path)
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

