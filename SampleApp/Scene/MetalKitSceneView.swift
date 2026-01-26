#if os(iOS) || os(macOS)

import SwiftUI
import MetalKit

#if os(macOS)
private typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS)
private typealias ViewRepresentable = UIViewRepresentable
#endif

class MetalView: MTKView{
    var renderer: MetalKitSceneRenderer?
    
    override var acceptsFirstResponder: Bool { return true }

    func initMe(){
        if let metalDevice = MTLCreateSystemDefaultDevice() {
           self.device = metalDevice
        }
        self.renderer = MetalKitSceneRenderer(self)!
        self.delegate = renderer
        if !self.becomeFirstResponder() {
            print("Could not get first responder")
        }
    }
    
    public override init(frame frameRect: CGRect, device: (any MTLDevice)?){
        super.init(frame: frameRect, device:device)
        initMe()
    }
    
    public required init(coder:NSCoder){
        super.init(coder: coder)
        initMe()
    }
    
    override func mouseDragged(with event: NSEvent) {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            //Move
            print("Moved ", event)
        }
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 14 {
            print("Toggled navigation mode")
            self.renderer?.toggleRotation()
        }
        print("Key down: \(event.characters!)")
    }
}

struct MetalKitSceneView: ViewRepresentable {
    var modelIdentifier: ModelIdentifier?

    class Coordinator {
        var renderer: MetalKitSceneRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

#if os(macOS)
    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#elseif os(iOS)
    func makeUIView(context: UIViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#endif

    private func makeView(_ coordinator: Coordinator) -> MTKView {

        let metalKitView = MetalView()
        coordinator.renderer = metalKitView.renderer
        Task {
            do {
                try await metalKitView.renderer!.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }

        return metalKitView
    }

#if os(macOS)
    func updateNSView(_ view: MTKView, context: NSViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#elseif os(iOS)
    func updateUIView(_ view: MTKView, context: UIViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#endif

    private func updateView(_ coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        Task {
            do {
                try await renderer.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }
    }
}

#endif // os(iOS) || os(macOS)
