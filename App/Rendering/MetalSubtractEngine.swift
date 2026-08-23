import Foundation
import Metal
import FitsnFinishCore

/// GPU implementation of the hybrid engine's per-pixel stages. All
/// megapixel-scale loops — physical prior render, masked cell-median
/// sampling, surface render, and the final blend — run as compute kernels
/// from `SubtractEngine.metal`; the CPU keeps only the tiny least-squares
/// solves and sigma-clip logic (shared with the reference path through
/// `PolynomialFitter`). Every entry point returns nil when Metal is
/// unavailable so callers fall back to the CPU pipeline.
final class MetalSubtractEngine: @unchecked Sendable {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let subtractPipeline: MTLComputePipelineState?
    private let priorPipeline: MTLComputePipelineState?
    private let medianPipeline: MTLComputePipelineState?
    private let surfacePipeline: MTLComputePipelineState?

    private struct SubtractParams {
        var physicsStrength: Float
        var priorGain: Float
        var priorMean: Float
        var surfaceMean: Float
    }

    private struct PriorParams {
        var tau: Float
        var extinction: Float
        var pixScaleDegrees: Float
        var rotationSine: Float
        var rotationCosine: Float
        var domeAzimuthDegrees: Float
        var domeIntensity: Float
        var sampleCount: UInt32
        var width: UInt32
        var height: UInt32
    }

    private struct MedianParams {
        var width: UInt32
        var height: UInt32
        var spacing: UInt32
        var cellsX: UInt32
        var cellsY: UInt32
        var threshold: Float
        var physicsStrength: Float
        var priorGain: Float
        var priorMean: Float
    }

    private struct SurfaceParams {
        var width: UInt32
        var height: UInt32
        var degree: UInt32
        var c0: Float, c1: Float, c2: Float, c3: Float, c4: Float, c5: Float
    }

    init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        if let device, let library = Self.loadLibrary(device: device) {
            func pipeline(_ name: String) -> MTLComputePipelineState? {
                library.makeFunction(name: name).flatMap {
                    try? device.makeComputePipelineState(function: $0)
                }
            }
            subtractPipeline = pipeline("subtract_gradients")
            priorPipeline = pipeline("render_prior")
            medianPipeline = pipeline("cell_median")
            surfacePipeline = pipeline("render_surface")
        } else {
            subtractPipeline = nil
            priorPipeline = nil
            medianPipeline = nil
            surfacePipeline = nil
        }
    }

    static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        // Test harnesses point straight at the shader source.
        if let path = ProcessInfo.processInfo.environment["FF_METAL_SOURCE"],
           let source = try? String(contentsOfFile: path, encoding: .utf8) {
            return try? device.makeLibrary(source: source, options: nil)
        }
        #if !FF_HARNESS
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
        #endif
        return nil
    }

    // MARK: Full GPU hybrid pipeline (one channel plane)

    struct PlaneOutput {
        let final: [Float]
        /// Diagnostics: the actual surfaces that were subtracted, for the
        /// app's Physical model / Polynomial surface view modes.
        let prior: [Float]
        let surface: [Float]
    }

    /// Runs physics prior → gain fit → masked cell medians → sigma-clipped
    /// surface fit → blend for one plane. Returns nil (fall back to CPU)
    /// when Metal or any kernel is unavailable.
    func processPlane(
        pixels: [Float], width: Int, height: Int,
        renderModel: AtmosphericModel.RenderModel,
        physicsStrength: Float, fitter: PolynomialFitter
    ) -> PlaneOutput? {
        guard let device, let queue,
              let subtractPipeline, let priorPipeline,
              let medianPipeline, let surfacePipeline,
              fitter.sampleSpacing <= 16,
              pixels.count == width * height
        else { return nil }

        guard
            let imageTexture = makeTexture(
                device: device, pixels: pixels, width: width, height: height,
                format: .r32Float, writable: false
            ),
            let priorTexture = makeTexture(
                device: device, pixels: nil, width: width, height: height,
                format: .r32Float, writable: true
            ),
            let surfaceTexture = makeTexture(
                device: device, pixels: nil, width: width, height: height,
                format: .r32Float, writable: true
            ),
            let outputTexture = makeTexture(
                device: device, pixels: nil, width: width, height: height,
                format: .rgba32Float, writable: true
            )
        else { return nil }

        // 1. Physical prior on GPU (airmass + dome + moon, time-averaged).
        let sampleCount = min(renderModel.samples.count, 3)
        var priorParams = PriorParams(
            tau: Float(renderModel.opticalDepth),
            extinction: Float(renderModel.extinction),
            pixScaleDegrees: Float(renderModel.pixelScaleDegrees),
            rotationSine: Float(renderModel.rotationSine),
            rotationCosine: Float(renderModel.rotationCosine),
            domeAzimuthDegrees: Float(renderModel.lightDomeAzimuthDegrees),
            domeIntensity: Float(renderModel.lightDomeIntensity),
            sampleCount: UInt32(sampleCount),
            width: UInt32(width), height: UInt32(height)
        )
        var sampleValues = [Float]()
        for sample in renderModel.samples.prefix(sampleCount) {
            sampleValues.append(Float(sample.altitudeCenterDegrees))
            sampleValues.append(Float(sample.azimuthCenterDegrees))
            sampleValues.append(Float(sample.moonAltitudeDegrees))
            sampleValues.append(Float(sample.moonAzimuthDegrees))
            sampleValues.append(Float(sample.moonFactor))
        }
        guard let sampleBuffer = device.makeBuffer(
            bytes: sampleValues,
            length: sampleValues.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else { return nil }
        guard let priorCommands = queue.makeCommandBuffer(),
              let priorEncoder = priorCommands.makeComputeCommandEncoder()
        else { return nil }
        priorEncoder.setComputePipelineState(priorPipeline)
        priorEncoder.setTexture(priorTexture, index: 0)
        priorEncoder.setBytes(&priorParams, length: MemoryLayout<PriorParams>.stride, index: 0)
        priorEncoder.setBuffer(sampleBuffer, offset: 0, index: 1)
        let priorThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        priorEncoder.dispatchThreadgroups(
            MTLSize(
                width: (width + 15) / 16, height: (height + 15) / 16, depth: 1
            ),
            threadsPerThreadgroup: priorThreadgroup
        )
        priorEncoder.endEncoding()
        priorCommands.commit()
        priorCommands.waitUntilCompleted()

        // 2. Prior gain (least squares) needs the prior values on CPU.
        guard let prior = readSingleChannel(priorTexture, width: width, height: height)
        else { return nil }
        let (gain, priorMean) = AtmosphericModel.priorGain(pixels: pixels, prior: prior)

        // 3. Bright-star threshold from a strided residual sample.
        let stride = max(1, pixels.count / 100_000)
        var residualSample: [Float] = []
        residualSample.reserveCapacity(pixels.count / stride + 1)
        var k = 0
        while k < pixels.count {
            let correction = physicsStrength * gain * (prior[k] - priorMean)
            residualSample.append(max(pixels[k] - correction, 0))
            k += stride
        }
        let stats = PolynomialFitter.robustStatistics(of: residualSample)
        let threshold = Float(stats.median + fitter.maskSigma * stats.sigma)

        // 4. Masked cell medians on GPU.
        let spacing = fitter.sampleSpacing
        let cellsX = (width + spacing - 1) / spacing
        let cellsY = (height + spacing - 1) / spacing
        let cellCount = cellsX * cellsY
        guard
            let medianBuffer = device.makeBuffer(
                length: cellCount * MemoryLayout<Float>.stride, options: .storageModeShared
            ),
            let maskedBuffer = device.makeBuffer(
                length: cellCount * MemoryLayout<Float>.stride, options: .storageModeShared
            )
        else { return nil }

        var medianParams = MedianParams(
            width: UInt32(width), height: UInt32(height), spacing: UInt32(spacing),
            cellsX: UInt32(cellsX), cellsY: UInt32(cellsY),
            threshold: threshold, physicsStrength: physicsStrength,
            priorGain: gain, priorMean: priorMean
        )
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { return nil }
        encoder.setComputePipelineState(medianPipeline)
        encoder.setTexture(imageTexture, index: 0)
        encoder.setTexture(priorTexture, index: 1)
        encoder.setBuffer(medianBuffer, offset: 0, index: 0)
        encoder.setBuffer(maskedBuffer, offset: 0, index: 1)
        encoder.setBytes(&medianParams, length: MemoryLayout<MedianParams>.stride, index: 2)
        let cellThreadgroup = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (cellsX + 7) / 8, height: (cellsY + 7) / 8, depth: 1
            ),
            threadsPerThreadgroup: cellThreadgroup
        )
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        let medianPointer = medianBuffer.contents().bindMemory(to: Float.self, capacity: cellCount)
        let maskedPointer = maskedBuffer.contents().bindMemory(to: Float.self, capacity: cellCount)
        let medians = (0 ..< cellCount).map { Double(medianPointer[$0]) }
        let maskedFractions = (0 ..< cellCount).map { Double(maskedPointer[$0]) }

        // 5. Sigma-clipped low-order fit (shared with the CPU path).
        let samples = fitter.assembleSamples(
            cellMedians: medians, maskedFractions: maskedFractions,
            cellsX: cellsX, cellsY: cellsY, width: width, height: height
        )
        guard let surface = try? fitter.fit(samples: samples, width: width, height: height)
        else { return nil }

        // 6. Surface render on GPU.
        var coefficients = surface.coefficients.map(Float.init)
        while coefficients.count < 6 { coefficients.append(0) }
        var surfaceParams = SurfaceParams(
            width: UInt32(width), height: UInt32(height),
            degree: UInt32(fitter.degree.rawValue),
            c0: coefficients[0], c1: coefficients[1], c2: coefficients[2],
            c3: coefficients[3], c4: coefficients[4], c5: coefficients[5]
        )
        guard dispatch(
            queue: queue, pipeline: surfacePipeline,
            textures: [surfaceTexture],
            bytes: &surfaceParams, length: MemoryLayout<SurfaceParams>.stride,
            gridWidth: width, gridHeight: height
        ) else { return nil }

        // 7. Final blend on GPU.
        var subtractParams = SubtractParams(
            physicsStrength: physicsStrength,
            priorGain: gain,
            priorMean: priorMean,
            surfaceMean: Float(surface.gridMean())
        )
        guard let blend = queue.makeCommandBuffer(),
              let blendEncoder = blend.makeComputeCommandEncoder()
        else { return nil }
        blendEncoder.setComputePipelineState(subtractPipeline)
        blendEncoder.setTexture(imageTexture, index: 0)
        blendEncoder.setTexture(priorTexture, index: 1)
        blendEncoder.setTexture(surfaceTexture, index: 2)
        blendEncoder.setTexture(outputTexture, index: 3)
        blendEncoder.setBytes(&subtractParams, length: MemoryLayout<SubtractParams>.stride, index: 0)
        let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
        blendEncoder.dispatchThreadgroups(
            MTLSize(
                width: (width + threadgroup.width - 1) / threadgroup.width,
                height: (height + threadgroup.height - 1) / threadgroup.height,
                depth: 1
            ),
            threadsPerThreadgroup: threadgroup
        )
        blendEncoder.endEncoding()
        blend.commit()
        blend.waitUntilCompleted()

        guard let renderedSurface = readSingleChannel(surfaceTexture, width: width, height: height)
        else { return nil }
        return PlaneOutput(
            final: readRGBAFirstChannel(outputTexture, width: width, height: height),
            prior: prior,
            surface: renderedSurface
        )
    }

    // MARK: Legacy single-blend entry (kept for the CPU-computed path)

    func subtract(
        image: [Float], prior: [Float], surface: [Float],
        width: Int, height: Int, physicsStrength: Float
    ) -> [Float]? {
        guard let device, let queue, let subtractPipeline,
              image.count == width * height,
              prior.count == image.count, surface.count == image.count
        else { return nil }

        guard
            let imageTexture = makeTexture(
                device: device, pixels: image, width: width, height: height,
                format: .r32Float, writable: false
            ),
            let priorTexture = makeTexture(
                device: device, pixels: prior, width: width, height: height,
                format: .r32Float, writable: false
            ),
            let surfaceTexture = makeTexture(
                device: device, pixels: surface, width: width, height: height,
                format: .r32Float, writable: false
            ),
            let outputTexture = makeTexture(
                device: device, pixels: nil, width: width, height: height,
                format: .rgba32Float, writable: true
            )
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
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (width + threadgroup.width - 1) / threadgroup.width,
                height: (height + threadgroup.height - 1) / threadgroup.height,
                depth: 1
            ),
            threadsPerThreadgroup: threadgroup
        )
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        return readRGBAFirstChannel(outputTexture, width: width, height: height)
    }

    // MARK: Helpers

    private func dispatch(
        queue: MTLCommandQueue, pipeline: MTLComputePipelineState,
        textures: [MTLTexture], bytes: UnsafeMutableRawPointer, length: Int,
        gridWidth: Int, gridHeight: Int
    ) -> Bool {
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { return false }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        encoder.setBytes(bytes, length: length, index: 0)
        let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (gridWidth + threadgroup.width - 1) / threadgroup.width,
                height: (gridHeight + threadgroup.height - 1) / threadgroup.height,
                depth: 1
            ),
            threadsPerThreadgroup: threadgroup
        )
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return true
    }

    private func readSingleChannel(
        _ texture: MTLTexture, width: Int, height: Int
    ) -> [Float]? {
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return values
    }

    private func readRGBAFirstChannel(
        _ texture: MTLTexture, width: Int, height: Int
    ) -> [Float] {
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        var result = [Float](repeating: 0, count: width * height)
        for k in 0 ..< result.count {
            result[k] = rgba[k * 4]
        }
        return result
    }

    private func makeTexture(
        device: MTLDevice, pixels: [Float]?, width: Int, height: Int,
        format: MTLPixelFormat, writable: Bool
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = writable ? [.shaderWrite, .shaderRead] : [.shaderRead]
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
