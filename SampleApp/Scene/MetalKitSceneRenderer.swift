#if os(iOS) || os(macOS)

import Metal
import MetalKit
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SwiftUI
import Carbon
import CoreImage
import CoreImage.CIFilterBuiltins


struct Camera{
    private var position:SIMD3<Float> = .zero
    private var rotation:matrix_float3x3 = matrix_identity_float3x3
    
    mutating func resetToIdentity(){
        position = .zero
        rotation = matrix_identity_float3x3
    }
    
    func getWorldTransform() -> matrix_float4x4{
        let pos = (position)
        var result = matrix_float4x4()
        result.columns.0 = SIMD4<Float>(rotation.columns.0.x, rotation.columns.0.y, rotation.columns.0.z, 0.0)
        result.columns.1 = SIMD4<Float>(rotation.columns.1.x, rotation.columns.1.y, rotation.columns.1.z, 0.0)
        result.columns.2 = SIMD4<Float>(rotation.columns.2.x, rotation.columns.2.y, rotation.columns.2.z, 0.0)
        result.columns.3 = SIMD4<Float>(pos.x, pos.y, pos.z, 1.0)
        return result
    }
    
    func getUpAxis() -> SIMD3<Float>{
        return rotation.columns.1
    }
    
    mutating func rotateAround(axis:SIMD3<Float>, angle:Float, rotationCenter:SIMD3<Float>){
        let rot = matrix3x3_rotation(radians: angle, axis: axis)
        self.rotation = rot * self.rotation
        self.position = (rot * (self.position - rotationCenter)) + rotationCenter
    }
    
    mutating func rotateLocally(pitch:Float, yaw:Float) {
        let yawMat = matrix3x3_rotation(radians: yaw, axis: simd_float3(0, 1, 0))
        let pitchMat = matrix3x3_rotation(radians: pitch, axis: simd_float3(1, 0, 0))
        let transform = pitchMat * yawMat
        
        self.rotation = transform * self.rotation
        self.position = transform * self.position
    }
    
    mutating func moveLocally(translation:SIMD3<Float>){
        self.position += translation
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
    var movingForward: Bool = false
    var movingBackward: Bool = false
    var movingLeft: Bool = false
    var movingRight: Bool = false
    var movingUp: Bool = false
    var movingDown: Bool = false

    var drawableSize: CGSize = .zero

    private var lastCPUTimestamp: ContinuousClock.Instant? = nil
    private let clock = ContinuousClock()
    
    private var cpuTimings :Array<Double> = Array()
    private var gpuTimings :Array<Double> = Array()

    // Reusable CIContext for PNG image saving (expensive to create, so cached).
    private lazy var ciContext: CIContext = CIContext(mtlDevice: device)

    // Tracks all in-flight PNG save tasks so we can wait for them before exit.
    private let imageSaveGroup = DispatchGroup()

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
            splat.useTightestCulling = false
            splat.usePolynomial = false
            try await splat.read(from: url)
            splat.onSortComplete = { (duration :TimeInterval) -> Void in
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
        
        camera.resetToIdentity()
        camera.moveLocally(translation: simd_float3(-1, 0, Constants.modelCenterZ))
    }

    // MARK: - Viewport helpers

    private var interactiveViewport: ModelRendererViewportDescriptor {
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

    private func cameraViewport(for cam: CameraData) -> ModelRendererViewportDescriptor {
        let aspectRatio = Float(drawableSize.width / drawableSize.height)
        let viewport = MTLViewport(originX: 0, originY: 0,
                                   width: drawableSize.width, height: drawableSize.height,
                                   znear: 0, zfar: 1)
        return ModelRendererViewportDescriptor(
            viewport: viewport,
            projectionMatrix: cam.projectionMatrix(aspectRatio: aspectRatio),
            viewMatrix: cam.viewMatrix,
            screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height))
        )
    }

    // MARK: - Image saving

    /// Saves the contents of a Metal texture as a PNG file.
    /// Must be called after the GPU command buffer has completed.
    private func saveTexture(_ texture: MTLTexture, toDirectory dir: URL, named name: String) {
        // Convert bgra8Unorm_srgb texture to a CIImage, then write PNG.
        let ciImage = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])!
            .oriented(.downMirrored)  // Metal textures are flipped relative to image convention
        let destURL = dir.appendingPathComponent("\(name).png")
        do {
            try ciContext.writePNGRepresentation(of: ciImage,
                                                 to: destURL,
                                                 format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        } catch {
            Self.log.error("Failed to save image \(name): \(error)")
        }
    }

    private func updateRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }
        guard let lastRotationUpdateTimestamp else { return }
        let delta = now.timeIntervalSince(lastRotationUpdateTimestamp)
        
        if(self.rotating) {
            let angle = (Constants.rotationPerSecond * delta).radians
            camera.rotateAround(axis: camera.getUpAxis(), angle: Float(angle), rotationCenter: simd_float3(0, 0, Constants.modelCenterZ))
            //camera.rotateAround(axis: Constants.rotationAxis, angle: Float(angle), rotationCenter: simd_float3(0, 0, Constants.modelCenterZ))
        }
        
        var movement = simd_float3(0, 0, 0)
        if movingForward {movement.z += 1}
        if movingBackward {movement.z -= 1}
        if movingLeft {movement.x += 1}
        if movingRight {movement.x -= 1}
        if movingUp {movement.y -= 1}
        if movingDown {movement.y += 1}
        
        movement *= Float(delta) * 2
        
        self.camera.moveLocally(translation: movement)
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
            let speed = Float(0.005)
            camera.rotateLocally(pitch: speed * Float(event.deltaY), yaw: speed * Float(event.deltaX))
        }
    }
    
    public func keyDown(event:NSEvent){
        if event.keyCode == kVK_ANSI_T {
            self.rotating = !self.rotating
            lastRotationUpdateTimestamp = Date()
        }
        else if event.keyCode == kVK_ANSI_W {
            self.movingForward = true
        }
        else if event.keyCode == kVK_ANSI_A {
            self.movingLeft = true
        }
        else if event.keyCode == kVK_ANSI_S {
            self.movingBackward = true
        }
        else if event.keyCode == kVK_ANSI_D {
            self.movingRight = true
        }
        else if event.keyCode == kVK_ANSI_E {
            self.movingUp = true
        }
        else if event.keyCode == kVK_ANSI_Q {
            self.movingDown = true
        }
        print("Key down: \(event.characters!)")
    }
    
    public func keyUp(event:NSEvent){
        if event.keyCode == kVK_ANSI_T {
        }
        else if event.keyCode == kVK_ANSI_W {
            self.movingForward = false
        }
        else if event.keyCode == kVK_ANSI_A {
            self.movingLeft = false
        }
        else if event.keyCode == kVK_ANSI_S {
            self.movingBackward = false
        }
        else if event.keyCode == kVK_ANSI_D {
            self.movingRight = false
        }
        else if event.keyCode == kVK_ANSI_E {
            self.movingUp = false
        }
        else if event.keyCode == kVK_ANSI_Q {
            self.movingDown = false
        }
    }

    func draw(in view: MTKView) {
        guard let modelRenderer else { return }
        guard let drawable = view.currentDrawable else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        let cpuDuration = timeDelta()
        let cpuMS = Double(cpuDuration.attoseconds) / 1e15
        cpuTimings.append(cpuMS)
        
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
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        // ── Camera-based benchmark mode ──────────────────────────────────────────────
        let benchmarkCameras = BenchmarkState.shared.cameras
        let isCameraBenchmark = BenchmarkState.shared.isBenchmarkMode && !benchmarkCameras.isEmpty

        // Pick the viewport to render this frame.
        let renderViewport: ModelRendererViewportDescriptor
        let cameraIndexThisFrame: Int
        let cameraNameThisFrame: String

        if isCameraBenchmark {
            cameraIndexThisFrame = BenchmarkState.shared.currentCameraIndex
            guard cameraIndexThisFrame < benchmarkCameras.count else {
                // All cameras rendered — should already have exited, but guard just in case.
                inFlightSemaphore.signal()
                return
            }
            let cam = benchmarkCameras[cameraIndexThisFrame]
            cameraNameThisFrame = cam.img_name
            renderViewport = cameraViewport(for: cam)
            // Advance the index now (on MainActor) so the next draw() picks the next camera.
            BenchmarkState.shared.currentCameraIndex += 1
        } else {
            cameraIndexThisFrame = -1
            cameraNameThisFrame = ""
            renderViewport = interactiveViewport
            if !BenchmarkState.shared.isBenchmarkMode {
                updateRotation()
            }
        }

        let colorTexture = drawable.texture
        let saveDir = BenchmarkState.shared.saveImagesURL
        let imgName = cameraNameThisFrame
        let ciCtx = ciContext  // capture for background thread

        // ── Create a CPU-readable staging texture for image saving ───────────────────
        // We CANNOT read directly from the drawable texture after present() because
        // CAMetalDrawable textures are recycled immediately. We blit into a staging
        // texture (managed/shared storage) that we own and can safely read back.
        let stagingTexture: MTLTexture?
        if saveDir != nil && isCameraBenchmark && !imgName.isEmpty {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorTexture.pixelFormat,
                width: colorTexture.width,
                height: colorTexture.height,
                mipmapped: false)
            desc.usage = [.shaderRead]
#if os(macOS)
            desc.storageMode = .managed
#else
            desc.storageMode = .shared
#endif
            stagingTexture = device.makeTexture(descriptor: desc)
        } else {
            stagingTexture = nil
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { [weak self] (_ commandBuffer) -> Swift.Void in
            guard let self = self else { semaphore.signal(); return }

            let gpuMS = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000.0

            Task { @MainActor in
                self.gpuTimings.append(gpuMS)

                if isCameraBenchmark {
                    let done = BenchmarkState.shared.currentCameraIndex >= benchmarkCameras.count
                        && self.gpuTimings.count >= benchmarkCameras.count

                    // Save the rendered image from the stable staging texture.
                    // Each save enters the DispatchGroup so we can wait for all before exit.
                    if let saveDir, let staging = stagingTexture, !imgName.isEmpty {
                        let saveGroup = self.imageSaveGroup
                        saveGroup.enter()
                        Task.detached(priority: .utility) {
                            defer { saveGroup.leave() }
                            guard let ciImage = CIImage(mtlTexture: staging,
                                                        options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
                            else {
                                print("[Benchmark] Failed to create CIImage for \(imgName)")
                                return
                            }
                            let flipped = ciImage.oriented(.downMirrored)
                            let destURL = saveDir.appendingPathComponent(imgName + ".png")
                            do {
                                try ciCtx.writePNGRepresentation(
                                    of: flipped,
                                    to: destURL,
                                    format: .RGBA8,
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                            } catch {
                                print("[Benchmark] Failed to save \(imgName): \(error)")
                            }
                        }
                    }

                    if done {
                        let avgGPU = self.gpuTimings.reduce(0, +) / Double(self.gpuTimings.count)
                        let avgCPU = self.cpuTimings.reduce(0, +) / Double(self.cpuTimings.count)
                        let camCount = benchmarkCameras.count
                        let saveGroup = self.imageSaveGroup
                        // Wait for ALL in-flight saves to finish before printing results and exiting.
                        // Must use a plain GCD thread — DispatchGroup.wait() is unavailable in async contexts.
                        DispatchQueue.global(qos: .utility).async {
                            saveGroup.wait()
                            print("Benchmark Finished. Rendered \(camCount) cameras. Average time CPU \(avgCPU) ms, GPU \(avgGPU) ms")
                            fflush(stdout)
                            exit(0)
                        }
                    }
                } else if BenchmarkState.shared.isBenchmarkMode
                            && self.gpuTimings.count >= BenchmarkState.shared.benchmarkFrameCount {
                    // Fallback: frame-count-based benchmark (no cameras.json).
                    print("Benchmark Finished. Average time CPU \(TailMean(array: self.cpuTimings)) ms, GPU \(TailMean(array: self.gpuTimings)) ms")
                    fflush(stdout)
                    exit(0)
                }
            }
            semaphore.signal()
        }

        let didRender: Bool
        do {
            didRender = try modelRenderer.render(viewports: [renderViewport],
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

        // Blit the rendered drawable into our staging texture BEFORE presenting,
        // so we have a stable CPU-readable copy that won't be recycled by Metal.
        if let staging = stagingTexture, didRender,
           let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.copy(from: colorTexture,
                             sourceSlice: 0, sourceLevel: 0,
                             sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                             sourceSize: MTLSize(width: colorTexture.width,
                                                 height: colorTexture.height, depth: 1),
                             to: staging,
                             destinationSlice: 0, destinationLevel: 0,
                             destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
#if os(macOS)
            // Managed textures need an explicit synchronize to make GPU writes visible to CPU.
            blitEncoder.synchronize(resource: staging)
#endif
            blitEncoder.endEncoding()
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
