import Foundation
import Metal
import FitsnFinishCore

/// GPU implementation of the final blend step, driving the
/// `subtract_gradients` kernel in `SubtractEngine.metal`. Returns nil when
/// Metal is unavailable so callers can fall back to the CPU pipeline result.
final class MetalSubtractEngine: @unchecked Sendable {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let subtractPipeline: MTLComputePipelineState?

    private struct SubtractParams {
        var physicsStrength: Float
        var priorGain: Float
        var priorMean: Float
        var surfaceMean: Float
    }

    init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        if let device, let library = Self.loadLibrary(device: device),
           let function = library.makeFunction(name: "subtract_gradients") {
            subtractPipeline = try? device.makeComputePipelineState(function: function)
        } else {
            subtractPipeline = nil
        }
    }

    static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        // Xcode-driven builds compile Metal/SubtractEngine.metal into the
        // module bundle as a metallib…
        if let url = Bundle.module.url(forResource: "default", withExtension: "metallib"),
           let library = try? device.makeLibrary(URL: url) {
            return library
        }
        if let library = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            return library
        }
        // …while plain `swift build` ships the raw source; compile it at
        // runtime instead.
        if let url = Bundle.module.url(forResource: "SubtractEngine", withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return try? device.makeLibrary(source: source, options: nil)
        }
        return nil
    }

    func subtract(
        image: [Float], prior: [Float], surface: [Float],
        width: Int, height: Int, physicsStrength: Float
    ) -> [Float]? {
        guard let device, let queue, let subtractPipeline,
              image.count == width * height,
              prior.count == image.count, surface.count == image.count
        else { return nil }

        guard
            let imageTexture = makeTexture(device: device, pixels: image, width: width, height: height),
            let priorTexture = makeTexture(device: device, pixels: prior, width: width, height: height),
            let surfaceTexture = makeTexture(device: device, pixels: surface, width: width, height: height),
            let outputTexture = makeTexture(device: device, pixels: nil, width: width, height: height)
        else { return nil }

        let (gain, priorMean) = AtmosphericModel.priorGain(pixels: image, prior: prior)
        var params = SubtractParams(
            physicsStrength: physicsStrength,
            priorGain: gain,
            priorMean: priorMean,
            surfaceMean: surface.reduce(0, +) / Float(surface.count)
        )

        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { return nil }
        encoder.setComputePipelineState(subtractPipeline)
        encoder.setTexture(imageTexture, index: 0)
        encoder.setTexture(priorTexture, index: 1)
        encoder.setTexture(surfaceTexture, index: 2)
        encoder.setTexture(outputTexture, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<SubtractParams>.stride, index: 0)

        let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(
            width: (width + threadgroup.width - 1) / threadgroup.width,
            height: (height + threadgroup.height - 1) / threadgroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        var result = [Float](repeating: 0, count: image.count)
        // The output texture is RGBA float; pull the red channel.
        var rgba = [Float](repeating: 0, count: image.count * 4)
        rgba.withUnsafeMutableBytes { buffer in
            outputTexture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        for k in 0 ..< image.count {
            result[k] = rgba[k * 4]
        }
        return result
    }

    private func makeTexture(
        device: MTLDevice, pixels: [Float]?, width: Int, height: Int
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixels == nil ? .rgba32Float : .r32Float,
            width: width, height: height, mipmapped: false
        )
        descriptor.usage = pixels == nil ? [.shaderWrite, .shaderRead] : [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        if let pixels {
            pixels.withUnsafeBytes { buffer in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: buffer.baseAddress!,
                    bytesPerRow: width * MemoryLayout<Float>.size
                )
            }
        }
        return texture
    }
}
