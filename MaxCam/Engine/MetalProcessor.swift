import CoreVideo
import Foundation
import Metal

enum MetalProcessorError: Error {
    case unavailable
    case noShaderLibrary
    case noShaderFunction
    case textureCreation
}

/// Preview-only, realtime Metal pipeline.
///
/// It never touches the buffer that reaches the encoder: the log / wide-gamut
/// image goes straight from the camera to the recorder, and a display transform
/// is applied here purely for on-screen monitoring. This keeps "log master +
/// monitoring transform" honest — the display transform can never be baked in.
actor MetalProcessor {
    enum DisplayTransform: UInt32 {
        case passthrough = 0
        case approximateLogToDisplay = 1
        case p3ToRec709 = 2
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipelineState: MTLComputePipelineState

    init(device: MTLDevice? = nil) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalProcessorError.unavailable
        }
        self.device = resolved
        guard let queue = resolved.makeCommandQueue() else {
            throw MetalProcessorError.unavailable
        }
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        let attributes: [CFString: Any] = [kCVMetalTextureCacheMaximumTextureAgeKey: 2.0]
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            attributes as CFDictionary,
            resolved,
            nil,
            &cache
        ) == kCVReturnSuccess, let resolvedCache = cache else {
            throw MetalProcessorError.unavailable
        }
        self.textureCache = resolvedCache

        guard let library = resolved.makeDefaultLibrary() else {
            // No compiled shader library is embedded. The app keeps running with
            // AVFoundation's native preview tone-mapping; the extra monitoring
            // transforms simply stay unavailable.
            throw MetalProcessorError.noShaderLibrary
        }
        guard let function = library.makeFunction(name: "displayTransform") else {
            throw MetalProcessorError.noShaderFunction
        }
        self.pipelineState = try resolved.makeComputePipelineState(function: function)
    }

    /// Applies a display transform to a camera buffer, producing a BGRA buffer
    /// suitable for on-screen rendering.
    func process(
        _ source: CVPixelBuffer,
        transform: DisplayTransform = .passthrough
    ) throws -> CVPixelBuffer {
        let sourceTexture = try makeTexture(from: source)
        let width = sourceTexture.width
        let height = sourceTexture.height
        let outputBuffer = try makeOutputBuffer(width: width, height: height)
        let outputTexture = try makeTexture(from: outputBuffer)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalProcessorError.unavailable
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        var mode = transform.rawValue
        encoder.setBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outputBuffer
    }

    private func makeTexture(from buffer: CVPixelBuffer) throws -> MTLTexture {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let metalFormat: MTLPixelFormat

        // Only formats the shader can read directly are accepted. Guessing a
        // format here would silently corrupt the image.
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA:
            metalFormat = .bgra8Unorm
        case kCVPixelFormatType_64RGBAHalf:
            metalFormat = .rgba16Float
        default:
            throw MetalProcessorError.textureCreation
        }

        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            metalFormat,
            width,
            height,
            0,
            &texture
        )
        guard status == kCVReturnSuccess,
              let cvTexture = texture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture) else {
            throw MetalProcessorError.textureCreation
        }
        return metalTexture
    }

    private func makeOutputBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let resolvedPool = pool else {
            throw MetalProcessorError.textureCreation
        }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            resolvedPool,
            &buffer
        ) == kCVReturnSuccess, let resolvedBuffer = buffer else {
            throw MetalProcessorError.textureCreation
        }
        return resolvedBuffer
    }
}
