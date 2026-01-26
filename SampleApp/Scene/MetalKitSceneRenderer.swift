#if os(iOS) || os(macOS)

import Metal
import MetalKit
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SwiftUI


struct Camera{
    var position:SIMD3<Float> = .zero
    var rotation:matrix_float3x3 = matrix_identity_float3x3
    
    func getWorldTransform() -> matrix_float4x4{
        var translationMatrix: matrix_float4x4 = matrix_identity_float4x4
        translationMatrix.columns.3.x = position.x
        translationMatrix.columns.3.y = position.y
        translationMatrix.columns.3.z = position.z
        
        var rotation4 = matrix_float4x4()
        rotation4.columns.0 = SIMD4<Float>(rotation.columns.0.x, rotation.columns.0.y, rotation.columns.0.z, 0.0)
        rotation4.columns.1 = SIMD4<Float>(rotation.columns.1.x, rotation.columns.1.y, rotation.columns.1.z, 0.0)
        rotation4.columns.2 = SIMD4<Float>(rotation.columns.2.x, rotation.columns.2.y, rotation.columns.2.z, 0.0)
        rotation4.columns.3 = SIMD4<Float>(0.0, 0.0, 0.0, 1.0)
        
        return translationMatrix * rotation4
    }
    
    mutating func rotateAround(axis:SIMD3<Float>, angle:Float, rotationCenter:SIMD3<Float>){
        let rot = matrix3x3_rotation(radians: angle, axis: axis)
        self.rotation = rot * self.rotation
        self.position = (rot * (self.position - rotationCenter)) + rotationCenter
    }
}

@MainActor
class MetalKitSceneRenderer: NSObject, MTKViewDelegate {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "MetalKitSceneRenderer")

    let metalKitView: MTKView
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    var lastRotationUpdateTimestamp: Date? = nil
    var camera:Camera = Camera()
    var rotating: Bool = true

    var drawableSize: CGSize = .zero

    private var lastCPUTimestamp: ContinuousClock.Instant? = nil
    private let clock = ContinuousClock()
    
    private var cpuTimings :Array<Double> = Array()
    private var gpuTimings :Array<Double> = Array()

    init?(_ metalKitView: MTKView) {
        self.device = metalKitView.device!
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.metalKitView = metalKitView
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        modelRenderer = nil
        switch model {
        case .gaussianSplat(let url):
            let splat = try SplatRenderer(device: device,
                                          colorFormat: metalKitView.colorPixelFormat,
                                          depthFormat: metalKitView.depthStencilPixelFormat,
                                          sampleCount: metalKitView.sampleCount,
                                          maxViewCount: 1,
                                          maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            try await splat.read(from: url)
            splat.onSortComplete = { (duration :TimeInterval) -> Void in
                print("Sorted ", duration * 1000, " ms" )
            }
            modelRenderer = splat
        case .sampleBox:
            modelRenderer = try! SampleBoxRenderer(device: device,
                                                   colorFormat: metalKitView.colorPixelFormat,
                                                   depthFormat: metalKitView.depthStencilPixelFormat,
                                                   sampleCount: metalKitView.sampleCount,
                                                   maxViewCount: 1,
                                                   maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        case .none:
            break
        }
        
        camera.position = simd_float3(1, 0, Constants.modelCenterZ)
        camera.rotation = matrix_identity_float3x3
    }

    private var viewport: ModelRendererViewportDescriptor {
        let projectionMatrix = matrix_perspective_right_hand(fovyRadians: Float(Constants.fovy.radians),
                                                             aspectRatio: Float(drawableSize.width / drawableSize.height),
                                                             nearZ: 0.1,
                                                             farZ: 100.0)

        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

        let viewport = MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1)

        return ModelRendererViewportDescriptor(viewport: viewport,
                                               projectionMatrix: projectionMatrix,
                                               viewMatrix: camera.getWorldTransform() * commonUpCalibration,
                                               screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height)))
    }

    private func updateRotation() {
        if !self.rotating { return }
        
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }

        guard let lastRotationUpdateTimestamp else { return }
        let angle = (Constants.rotationPerSecond * now.timeIntervalSince(lastRotationUpdateTimestamp)).radians
        camera.rotateAround(axis: Constants.rotationAxis, angle: Float(angle), rotationCenter: simd_float3(0, 0, Constants.modelCenterZ))
    }
    
    private func timeDelta()->Duration {
        let lastTime = self.lastCPUTimestamp ?? self.clock.now
        let now = self.clock.now
        self.lastCPUTimestamp = now
        return now - lastTime
    }
    
    public func mousedDragged(event:NSEvent){
        if NSEvent.pressedMouseButtons & 1 != 0 {
            //Move
            print("Moved ", event)
        }
    }
    
    public func keyDown(event:NSEvent){
        if event.keyCode == 14 {
            self.rotating = !self.rotating
            lastRotationUpdateTimestamp = Date()
        }
        print("Key down: \(event.characters!)")
    }
    
    public func keyUp(event:NSEvent){
        
    }

    func draw(in view: MTKView) {
        guard let modelRenderer else { return }
        guard let drawable = view.currentDrawable else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        let cpuDuration = timeDelta()
        let cpuMS = Double(cpuDuration.attoseconds) / 1e15
        cpuTimings.append(cpuMS)
        
        //print("Frame time CPU: \(String(format:"%.3f", cpuMS)) ms")
        
        func TailMean(array :Array<Double> ) -> Double {
            let n = 60
            if(array.count > n)
            {
                return array[(array.count-n)...].reduce(0, +) / Double(n)
            }
            else {
                return array.reduce(0, +) / Double(array.count)
            }
        }
        print("Average time CPU \(TailMean(array: self.cpuTimings)). GPU \(TailMean(array: self.gpuTimings))")

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer) -> Swift.Void in
            // GPU times are in seconds
            let gpuMS = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000.0
            //print("Frame times  GPU: \(String(format: "%.3f", gpuMS)) ms")
            Task {await MainActor.run(body: {self.gpuTimings.append(gpuMS)})}
            semaphore.signal()
        }

        updateRotation()

        let didRender: Bool
        do {
            didRender = try modelRenderer.render(viewports: [viewport],
                                                 colorTexture: view.multisampleColorTexture ?? drawable.texture,
                                                 colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                                                 depthTexture: view.depthStencilTexture,
                                                 rasterizationRateMap: nil,
                                                 renderTargetArrayLength: 0,
                                                 to: commandBuffer)
        } catch {
            Self.log.error("Unable to render scene: \(error.localizedDescription)")
            didRender = false
        }

        // Only present if rendering occurred; otherwise drop the frame
        if didRender {
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()

        lastCPUTimestamp = clock.now
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }
}

#endif // os(iOS) || os(macOS)

