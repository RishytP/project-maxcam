import CoreVideo
import Foundation
import Metal
import MetalKit

/// Preview-only, realtime Metal pipeline. It never modifies the master
/// recording buffer: the log/wide-gamut image goes straight from the camera to
/// the encoder, while a display transform is applied here purely for on-screen
/// monitoring (Option A of the "LOG RECORDING + DISPLAY LUT" architecture).
actor MetalProcessor {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipelineState: MTLComputePipelineState

    enum State {
        case passthrough
        case appleLogTo709
        case p3To709
    }

    init(device: MTLDevice? = nil) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalProcessorError.unavailable
        }
        self.device = resolved
        guard let queue = self.device.makeCommandQueue() else { throw MetalProcessorError.unavailable }
        commandQueue = queue

        guard let cache = MetalProcessor.makeTextureCache(self.device) else { throw MetalProcessorError.unavailable }
        textureCache = cache

        let library: MTLLibrary
        if let deviceLibrary = try? self.device.makeDefaultLibrary() {
            library = deviceLibrary
        } else if let url = Bundle.main.url(forResource: "MaxCamShaders", withExtension: "metallib"),
                  let lib = try? self.device.makeLibrary(filepath: url.path) {
            library = lib
        } else {
            // No compiled shader library embedded. The engine continues running
            // with AVCaptureVideoPreviewLayer's native display pipeline; the
            // monitoring transforms simply stay disabled.
            throw MetalProcessorError.noShaderLibrary
        }
        guard let fn = library.makeFunction(name: "displayTransform") else {
            throw MetalProcessorError.noShaderFunction
        }
        pipelineState = try self.device.makeComputePipelineState(function: fn)
    }

    /// Applies the display transform to a camera buffer, producing a new
    /// BGRA buffer suitable for MTKView / UIImage rendering.
    /// `state` decides whether a log/P3-to-sRGB conversion is applied.
    func process(_ source: CVPixelBuffer, state: State = .passthrough) throws -> CVPixelBuffer {
        // Create textures from the source.
        let (sourceTexture, _) = try textures(from: source)
        let outSize = CGSize(width: sourceTexture.width, height: sourceTexture.height)
        let outBuffer = try makeOutputBuffer(width: Int(outSize.width), height: Int(outSize.height))
        let (outputTexture, _) = try textures(from: outBuffer)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalProcessorError.unavailable
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        var mode: UInt32 = (state == .appleLogTo709) ? 1 : ((state == .p3To709) ? 2 : 0)
        encoder.setBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (sourceTexture.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (sourceTexture.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return outBuffer
    }

    private func textures(from buffer: CVPixelBuffer) throws -> (MTLTexture, CVMetalTexture) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let mtlFormat: MTLPixelFormat
        switch format {
        case kCVPixelFormatType_32BGRA:
            mtlFormat = .bgra8Unorm
        case kCVPixelFormatType_64RGBAHalf:
            mtlFormat = .rgba16Float
        default:
            mtlFormat = .bgra8Unorm
        }
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            mtlFormat,
            width,
            height,
            0,
            &texture
        ) == kCVReturnSuccess, let cvTexture = texture, let mtlTexture = CVMetalTextureGetTexture(cvTexture) else {
            throw MetalProcessorError.textureCreation
        }
        return (mtlTexture, cvTexture)
    }

    private func makeOutputBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw MetalProcessorError.textureCreation
        }
        return buffer
    }
}

enum MetalProcessorError: Error {
    case unavailable
    case noShaderLibrary
    case noShaderFunction
    case textureCreation
}

private extension MetalProcessor {
    static func makeTextureCache(_ device: MTLDevice) -> CVMetalTextureCache? {
        var cache: CVMetalTextureCache?
        let attrs: [CFString: Any] = [kCVMetalTextureCacheMaximumTextureAgeKey: 2.0]
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, attrs as CFDictionary, device, nil, &cache) == kCVReturnSuccess else {
            return nil
        }
        return cache
    }
}