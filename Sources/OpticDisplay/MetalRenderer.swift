import Foundation
import Metal
import OpticCore
import QuartzCore

public enum RendererError: Error, CustomStringConvertible {
    case noDevice
    case shaderCompilation(String)
    case pipeline(String)
    case texture(String)
    case commandBuffer
    case encoder

    public var description: String {
        switch self {
        case .noDevice: return "Metal device unavailable"
        case .shaderCompilation(let message): return "shader compilation failed: \(message)"
        case .pipeline(let message): return "pipeline creation failed: \(message)"
        case .texture(let message): return "texture creation failed: \(message)"
        case .commandBuffer: return "command buffer creation failed"
        case .encoder: return "render encoder creation failed"
        }
    }
}

/// Minimal SDR renderer: one pipeline, integer quads, a 1x1 white texture for
/// solid fills and one text texture per card. Shader source is compiled at
/// startup with `makeLibrary(source:)`; there is no offline metallib step and no
/// anti-aliasing, gradient or texture filtering.
public final class MetalRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let whiteTexture: MTLTexture
    private let sampler: MTLSamplerState

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct OpticVertexIn {
        float2 position;
        float2 uv;
        uchar4 color;
    };

    struct OpticVertexOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
    };

    vertex OpticVertexOut optic_vertex(
        const device OpticVertexIn *vertices [[buffer(0)]],
        constant float2 &drawableSize [[buffer(1)]],
        uint vid [[vertex_id]]
    ) {
        OpticVertexIn in = vertices[vid];
        float2 ndc = float2(
            in.position.x / drawableSize.x * 2.0 - 1.0,
            1.0 - in.position.y / drawableSize.y * 2.0
        );
        OpticVertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = in.uv;
        out.color = float4(in.color) / 255.0;
        return out;
    }

    fragment float4 optic_fragment(
        OpticVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        return in.color * tex.sample(samp, in.uv);
    }
    """

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.commandBuffer }
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: MetalRenderer.shaderSource, options: nil)
        } catch {
            throw RendererError.shaderCompilation(String(describing: error))
        }
        guard let vertexFunction = library.makeFunction(name: "optic_vertex"),
              let fragmentFunction = library.makeFunction(name: "optic_fragment")
        else {
            throw RendererError.shaderCompilation("missing optic_vertex/optic_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RendererError.pipeline(String(describing: error))
        }

        let whiteDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        whiteDescriptor.usage = .shaderRead
        whiteDescriptor.storageMode = .shared
        guard let white = device.makeTexture(descriptor: whiteDescriptor) else {
            throw RendererError.texture("white")
        }
        var pixel: UInt32 = 0xFFFF_FFFF
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                      withBytes: &pixel, bytesPerRow: 4)
        whiteTexture = white

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.texture("sampler")
        }
        self.sampler = sampler
    }

    /// Encodes the scene into a command buffer. The caller adds present/completion
    /// handlers, samples the submit time and commits.
    public func makeCommandBuffer(
        drawable: CAMetalDrawable,
        scene: Scene,
        text: CardText?
    ) -> MTLCommandBuffer? {
        makeCommandBuffer(into: drawable.texture, scene: scene, text: text)
    }

    /// Offscreen target used by the pixel-code test; production frames go
    /// through the drawable overload.
    public func makeCommandBuffer(
        into texture: MTLTexture,
        scene: Scene,
        text: CardText?
    ) -> MTLCommandBuffer? {
        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        var size = SIMD2<Float>(Float(texture.width), Float(texture.height))
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)

        if !scene.solid.isEmpty, let buffer = makeVertexBuffer(scene.solid) {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(whiteTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: scene.solid.count)
        }
        if !scene.text.isEmpty, let text, let buffer = makeVertexBuffer(scene.text) {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(text.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: scene.text.count)
        }
        encoder.endEncoding()
        return commandBuffer
    }

    private func makeVertexBuffer(_ vertices: [SceneVertex]) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        return device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<SceneVertex>.stride * vertices.count,
            options: .storageModeShared
        )
    }
}
