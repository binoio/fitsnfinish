import SwiftUI
import MetalKit

/// Aspect-fit Metal preview of a linear monochrome frame with a midtone
/// transfer function (MTF) stretch applied in the fragment shader, so the
/// linear data stays untouched and only the display is stretched.
struct MetalView {
    /// 1 (mono) or 3 (RGB) row-major channel planes.
    let planes: [[Float]]
    let width: Int
    let height: Int
    let midtone: Float

    func makeCoordinator() -> Renderer {
        Renderer()
    }

    private func makeView(coordinator: Renderer) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        coordinator.configure(view: view)
        updateView(view, coordinator: coordinator)
        return view
    }

    private func updateView(_ view: MTKView, coordinator: Renderer) {
        coordinator.update(planes: planes, width: width, height: height, midtone: midtone)
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }

    final class Renderer: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var sampler: MTLSamplerState?
        private var midtone: Float = 0.15

        // Display-only shading, compiled at runtime so the preview never
        // depends on the packaged metallib.
        private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VSOut { float4 position [[position]]; float2 uv; };

        vertex VSOut fullscreen_quad(uint vid [[vertex_id]],
                                     constant float2 &scale [[buffer(0)]]) {
            float2 corners[4] = { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
            VSOut out;
            out.position = float4(corners[vid] * scale, 0, 1);
            out.uv = float2((corners[vid].x + 1) * 0.5, 1 - (corners[vid].y + 1) * 0.5);
            return out;
        }

        fragment float4 mtf_display(VSOut in [[stage_in]],
                                    texture2d<float> image [[texture(0)]],
                                    sampler s [[sampler(0)]],
                                    constant float &midtone [[buffer(0)]]) {
            float3 x = clamp(image.sample(s, in.uv).rgb, 0.0f, 1.0f);
            float m = clamp(midtone, 1e-4f, 1.0f - 1e-4f);
            float3 y = ((m - 1.0f) * x) / ((2.0f * m - 1.0f) * x - m);
            return float4(y, 1.0f);
        }
        """

        func configure(view: MTKView) {
            guard let device = view.device else { return }
            self.device = device
            queue = device.makeCommandQueue()
            guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
            else { return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreen_quad")
            descriptor.fragmentFunction = library.makeFunction(name: "mtf_display")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)

            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        }

        /// Identifies the last-uploaded planes by their copy-on-write storage
        /// addresses, so midtone-slider updates skip the frame re-upload.
        private var uploadedStorage: [UnsafeRawPointer?] = []

        func update(planes: [[Float]], width: Int, height: Int, midtone: Float) {
            self.midtone = midtone
            guard let device, width > 0, height > 0, !planes.isEmpty,
                  planes.allSatisfy({ $0.count == width * height })
            else { return }

            let storage = planes.map {
                $0.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
            }
            let sizeChanged = texture?.width != width || texture?.height != height
            guard sizeChanged || storage != uploadedStorage else { return }

            if sizeChanged {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
                )
                descriptor.usage = [.shaderRead]
                descriptor.storageMode = .shared
                texture = device.makeTexture(descriptor: descriptor)
            }

            // Interleave planes into RGBA (mono replicates its single plane).
            let count = width * height
            let red = planes[0]
            let green = planes.count > 1 ? planes[1] : planes[0]
            let blue = planes.count > 2 ? planes[2] : green
            var rgba = [Float](repeating: 1, count: count * 4)
            rgba.withUnsafeMutableBufferPointer { buffer in
                for k in 0 ..< count {
                    buffer[k * 4] = red[k]
                    buffer[k * 4 + 1] = green[k]
                    buffer[k * 4 + 2] = blue[k]
                }
            }
            rgba.withUnsafeBytes { buffer in
                texture?.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: buffer.baseAddress!,
                    bytesPerRow: width * 4 * MemoryLayout<Float>.size
                )
            }
            uploadedStorage = storage
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let queue,
                  let pipeline,
                  let texture,
                  let sampler,
                  let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commands = queue.makeCommandBuffer(),
                  let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }

            // Aspect-fit scale for the fullscreen quad.
            let viewAspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
            let imageAspect = Float(texture.width) / Float(max(texture.height, 1))
            var scale = SIMD2<Float>(1, 1)
            if imageAspect > viewAspect {
                scale.y = viewAspect / imageAspect
            } else {
                scale.x = imageAspect / viewAspect
            }

            var midtoneValue = midtone
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&midtoneValue, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
        }
    }
}

#if os(macOS)
extension MetalView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        makeView(coordinator: context.coordinator)
    }

    func updateNSView(_ view: MTKView, context: Context) {
        updateView(view, coordinator: context.coordinator)
    }
}
#else
extension MetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        makeView(coordinator: context.coordinator)
    }

    func updateUIView(_ view: MTKView, context: Context) {
        updateView(view, coordinator: context.coordinator)
    }
}
#endif
