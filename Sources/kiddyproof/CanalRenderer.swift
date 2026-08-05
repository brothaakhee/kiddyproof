import Metal
import MetalKit
import QuartzCore
import simd
import CanalSim

// ===========================================================================
// The Metal side of the canalisation plant: a forward pass into an HDR target,
// then bloom, defocus and grade — a port of the reference's WebGL2 renderer
// (src/60_render.js) onto a CAMetalLayer hosted inside kiddyproof's overlay.
//
// The one structural difference is transparency. Every other scene in this app
// draws into the panel's CGContext over the parent's real desktop; this one
// draws into a Metal layer under that same context, and its output is
// PREMULTIPLIED — tissue occludes the desktop, glow adds to it. See the header
// of CanalShaders.metal.
// ===========================================================================

// Matches `Uniforms` in CanalShaders.metal. Each float3+float pair is packed as
// one SIMD4 because MSL gives float3 a 16-byte stride; writing it any other way
// silently shears every field after the first.
struct CanalUniforms {
    var vp: float4x4
    var eyeTime: SIMD4<Float>
    var keySway: SIMD4<Float>
    var keyColFogD: SIMD4<Float>
    var ambTopFogNear: SIMD4<Float>
    var ambBotPxScale: SIMD4<Float>
    var fogPad: SIMD4<Float>
}

struct CanalGradeUniforms {
    var bloomExposureGrainVignette: SIMD4<Float>
    var focusRangeDofTime: SIMD4<Float>
    var thresholdPad: SIMD4<Float>
}

final class CanalRenderer {

    // The device and the compiled library are process-wide: several panels (one
    // per screen) each render the same simulation, and paying for the shader
    // compile once per panel would be a stall per monitor at arm time.
    private static var sharedDevice: MTLDevice?
    private static var sharedLibrary: MTLLibrary?
    private static var libraryError: String?

    static func bootShared() {
        guard sharedDevice == nil else { return }
        guard let dev = MTLCreateSystemDefaultDevice() else {
            libraryError = "no Metal device"; return
        }
        sharedDevice = dev
        // The shader source ships as a resource and is compiled at launch rather
        // than built into a metallib: one source of truth, and no dependence on
        // how the build system chooses to treat a .metal file in a SwiftPM target.
        guard let url = Bundle.module.url(forResource: "CanalShaders", withExtension: "metal"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            libraryError = "CanalShaders.metal missing from the bundle"; return
        }
        do {
            sharedLibrary = try dev.makeLibrary(source: src, options: nil)
        } catch {
            libraryError = "shader compile failed: \(error)"
        }
    }

    static var unavailableReason: String? {
        bootShared()
        return sharedLibrary == nil ? (libraryError ?? "unknown") : nil
    }

    // The device every panel's CAMetalLayer must be bound to. Nil means this
    // machine cannot run the scene, and the Director simply never offers it.
    static var sharedMetalDevice: MTLDevice? {
        bootShared()
        return sharedLibrary == nil ? nil : sharedDevice
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let meshPipe: MTLRenderPipelineState
    private let linePipe: MTLRenderPipelineState
    private let pointPipe: MTLRenderPipelineState
    private let brightPipe: MTLRenderPipelineState
    private let blurPipe: MTLRenderPipelineState
    private let compPipe: MTLRenderPipelineState
    private let depthOn: MTLDepthStencilState
    private let depthTestNoWrite: MTLDepthStencilState
    private let depthNone: MTLDepthStencilState

    // vertex streams
    private var triBuf: MTLBuffer?
    private var lineBuf: MTLBuffer?
    private var ptBuf: MTLBuffer?
    private var moteBuf: MTLBuffer?
    private var nTri = 0, nLine = 0, nPt = 0, nMote = 0

    // offscreen targets
    private var width = 0, height = 0
    private var sceneMS: MTLTexture?, depthMS: MTLTexture?, zMS: MTLTexture?
    private var sceneTex: MTLTexture?, zTex: MTLTexture?
    private var brightTex: MTLTexture?, blurA: MTLTexture?, blurB: MTLTexture?
    private var dofA: MTLTexture?, dofB: MTLTexture?
    private let sampleCount = 4

    static let colorFormat = MTLPixelFormat.rgba16Float
    static let depthDataFormat = MTLPixelFormat.r16Float
    static let drawableFormat = MTLPixelFormat.bgra8Unorm

    init?() {
        CanalRenderer.bootShared()
        guard let dev = CanalRenderer.sharedDevice,
              let lib = CanalRenderer.sharedLibrary,
              let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q

        func makeWorldPipe(_ vs: String, _ fs: String, additive: Bool, writeDepthTarget: Bool)
            -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.rasterSampleCount = 4
            d.colorAttachments[0].pixelFormat = CanalRenderer.colorFormat
            d.colorAttachments[1].pixelFormat = CanalRenderer.depthDataFormat
            d.depthAttachmentPixelFormat = .depth32Float
            if additive {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                // colour adds; alpha is left alone because it is carrying coverage
                a.rgbBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.alphaBlendOperation = .add
                a.sourceAlphaBlendFactor = .zero
                a.destinationAlphaBlendFactor = .one
            }
            if !writeDepthTarget { d.colorAttachments[1].writeMask = [] }
            return try? dev.makeRenderPipelineState(descriptor: d)
        }

        func makeQuadPipe(_ fs: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "canal_quad_vs")
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = format
            return try? dev.makeRenderPipelineState(descriptor: d)
        }

        guard let mp = makeWorldPipe("canal_mesh_vs", "canal_mesh_fs", additive: false, writeDepthTarget: true),
              let lp = makeWorldPipe("canal_line_vs", "canal_line_fs", additive: true, writeDepthTarget: false),
              let pp = makeWorldPipe("canal_point_vs", "canal_point_fs", additive: true, writeDepthTarget: false),
              let bp = makeQuadPipe("canal_bright_fs", format: CanalRenderer.colorFormat),
              let blp = makeQuadPipe("canal_blur_fs", format: CanalRenderer.colorFormat),
              let cp = makeQuadPipe("canal_comp_fs", format: CanalRenderer.drawableFormat)
        else { return nil }
        meshPipe = mp; linePipe = lp; pointPipe = pp
        brightPipe = bp; blurPipe = blp; compPipe = cp

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let don = dev.makeDepthStencilState(descriptor: dd) else { return nil }
        depthOn = don
        dd.isDepthWriteEnabled = false
        guard let dno = dev.makeDepthStencilState(descriptor: dd) else { return nil }
        depthTestNoWrite = dno
        dd.depthCompareFunction = .always
        guard let dnone = dev.makeDepthStencilState(descriptor: dd) else { return nil }
        depthNone = dnone
    }

    // ---------------------------------------------------------------------
    // targets
    // ---------------------------------------------------------------------

    private func resize(_ w: Int, _ h: Int) {
        guard w != width || h != height, w > 1, h > 1 else { return }
        width = w; height = h
        let hw = max(2, w / 2), hh = max(2, h / 2)

        func tex(_ fmt: MTLPixelFormat, _ tw: Int, _ th: Int, ms: Bool, target: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: tw,
                                                             height: th, mipmapped: false)
            d.usage = target ? [.renderTarget, .shaderRead] : [.shaderRead]
            d.storageMode = .private
            if ms { d.textureType = .type2DMultisample; d.sampleCount = sampleCount; d.usage = [.renderTarget] }
            return device.makeTexture(descriptor: d)
        }

        sceneMS = tex(CanalRenderer.colorFormat, w, h, ms: true, target: true)
        zMS = tex(CanalRenderer.depthDataFormat, w, h, ms: true, target: true)
        depthMS = tex(.depth32Float, w, h, ms: true, target: true)
        sceneTex = tex(CanalRenderer.colorFormat, w, h, ms: false, target: true)
        zTex = tex(CanalRenderer.depthDataFormat, w, h, ms: false, target: true)
        brightTex = tex(CanalRenderer.colorFormat, hw, hh, ms: false, target: true)
        blurA = tex(CanalRenderer.colorFormat, hw, hh, ms: false, target: true)
        blurB = tex(CanalRenderer.colorFormat, hw, hh, ms: false, target: true)
        dofA = tex(CanalRenderer.colorFormat, hw, hh, ms: false, target: true)
        dofB = tex(CanalRenderer.colorFormat, hw, hh, ms: false, target: true)
    }

    // ---------------------------------------------------------------------
    // vertex upload
    // ---------------------------------------------------------------------

    func upload(_ B: Buffers) {
        nTri = B.triCount; nLine = B.lineCount; nPt = B.ptCount
        triBuf = upload(B.tri, count: B.triN, into: triBuf)
        lineBuf = upload(B.line, count: B.lineN, into: lineBuf)
        ptBuf = upload(B.pt, count: B.ptN, into: ptBuf)
    }

    // Drops of light travelling into the plant. These get their own stream
    // because they are rebuilt EVERY frame, while the plant's geometry is only
    // rebuilt ten times a second — a mote crossing the frame in a second would
    // visibly stutter on that clock, and rebuilding the whole specimen per frame
    // to carry a dozen points would be the wrong trade by two orders of magnitude.
    func uploadMotes(_ verts: [Float]) {
        nMote = verts.count / 7
        if nMote > 0 { moteBuf = upload(verts, count: verts.count, into: moteBuf) }
    }

    private func upload(_ src: [Float], count: Int, into existing: MTLBuffer?) -> MTLBuffer? {
        guard count > 0 else { return existing }
        let bytes = count * MemoryLayout<Float>.stride
        var buf = existing
        if buf == nil || buf!.length < bytes {
            buf = device.makeBuffer(length: max(bytes, 1 << 16), options: .storageModeShared)
        }
        guard let b = buf else { return nil }
        src.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                b.contents().copyMemory(from: base, byteCount: bytes)
            }
        }
        return b
    }

    // ---------------------------------------------------------------------
    // the frame
    // ---------------------------------------------------------------------

    func draw(to layer: CAMetalLayer, cam: Camera, pal: CanalSim.Palette, time: Float) {
        let dw = Int(layer.drawableSize.width), dh = Int(layer.drawableSize.height)
        guard dw > 1, dh > 1 else { return }
        resize(dw, dh)
        guard let drawable = layer.nextDrawable(),
              let sceneMS = sceneMS, let zMS = zMS, let depthMS = depthMS,
              let sceneTex = sceneTex, let zTex = zTex,
              let brightTex = brightTex, let blurA = blurA, let blurB = blurB,
              let dofA = dofA, let dofB = dofB,
              let cmd = queue.makeCommandBuffer() else { return }

        let aspect = Float(dw) / Float(dh)
        let proj = canalPerspective(fovY: cam.fov, aspect: aspect, near: 0.05, far: 400)
        let view = canalLookAt(eye: cam.eye, center: cam.target, up: SIMD3<Float>(0, 1, 0))
        var u = CanalUniforms(
            vp: proj * view,
            eyeTime: SIMD4<Float>(cam.eye.x, cam.eye.y, cam.eye.z, time),
            keySway: SIMD4<Float>(pal.key.x, pal.key.y, pal.key.z, pal.sway),
            keyColFogD: SIMD4<Float>(pal.keyCol.x, pal.keyCol.y, pal.keyCol.z, pal.fogD),
            ambTopFogNear: SIMD4<Float>(pal.ambTop.x, pal.ambTop.y, pal.ambTop.z, cam.fogNear),
            ambBotPxScale: SIMD4<Float>(pal.ambBot.x, pal.ambBot.y, pal.ambBot.z, Float(dh) * 0.9),
            fogPad: SIMD4<Float>(pal.fog.x, pal.fog.y, pal.fog.z, 0))

        // --- forward pass ------------------------------------------------
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = sceneMS
        rp.colorAttachments[0].resolveTexture = sceneTex
        rp.colorAttachments[0].loadAction = .clear
        // Cleared to fully transparent, NOT to a background colour: the overlay
        // is a window onto the parent's desktop and a scene that filled it would
        // black the machine out.
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .multisampleResolve
        rp.colorAttachments[1].texture = zMS
        rp.colorAttachments[1].resolveTexture = zTex
        rp.colorAttachments[1].loadAction = .clear
        // far away, so empty space defocuses rather than snapping into focus
        rp.colorAttachments[1].clearColor = MTLClearColor(red: 400, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[1].storeAction = .multisampleResolve
        rp.depthAttachment.texture = depthMS
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1.0
        rp.depthAttachment.storeAction = .dontCare

        if let e = cmd.makeRenderCommandEncoder(descriptor: rp) {
            e.setFragmentBytes(&u, length: MemoryLayout<CanalUniforms>.stride, index: 1)
            e.setVertexBytes(&u, length: MemoryLayout<CanalUniforms>.stride, index: 1)

            if nTri > 0, let tb = triBuf {
                e.setRenderPipelineState(meshPipe)
                e.setDepthStencilState(depthOn)
                e.setVertexBuffer(tb, offset: 0, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nTri)
            }
            // veins and needles: additive light, depth-tested but not written
            if nLine > 0, let lb = lineBuf {
                e.setRenderPipelineState(linePipe)
                e.setDepthStencilState(depthTestNoWrite)
                e.setVertexBuffer(lb, offset: 0, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nLine)
            }
            if nPt > 0, let pb = ptBuf {
                e.setRenderPipelineState(pointPipe)
                e.setDepthStencilState(depthTestNoWrite)
                e.setVertexBuffer(pb, offset: 0, index: 0)
                e.drawPrimitives(type: .point, vertexStart: 0, vertexCount: nPt)
            }
            // Drops of light, drawn last and WITHOUT the depth test: a mote
            // travelling into the canopy passes behind blades on its way in, and
            // losing sight of the thing the child just released is worse than the
            // small dishonesty of letting it show through.
            if nMote > 0, let mb = moteBuf {
                e.setRenderPipelineState(pointPipe)
                e.setDepthStencilState(depthNone)
                e.setVertexBuffer(mb, offset: 0, index: 0)
                e.drawPrimitives(type: .point, vertexStart: 0, vertexCount: nMote)
            }
            e.endEncoding()
        }

        var grade = CanalGradeUniforms(
            bloomExposureGrainVignette: SIMD4<Float>(pal.bloom, pal.exposure, pal.grain, pal.vignette),
            focusRangeDofTime: SIMD4<Float>(cam.dist, cam.dofRange, pal.dof, time),
            thresholdPad: SIMD4<Float>(pal.bloomThresh, 0, 0, 0))

        func quadPass(_ target: MTLTexture, _ pipe: MTLRenderPipelineState,
                      _ setup: (MTLRenderCommandEncoder) -> Void) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = target
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            guard let e = cmd.makeRenderCommandEncoder(descriptor: d) else { return }
            e.setRenderPipelineState(pipe)
            setup(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        // --- bloom ---------------------------------------------------------
        quadPass(brightTex, brightPipe) { e in
            e.setFragmentTexture(sceneTex, index: 0)
            e.setFragmentBytes(&grade, length: MemoryLayout<CanalGradeUniforms>.stride, index: 0)
        }
        var bloomSrc = brightTex
        let bw = Float(brightTex.width), bh = Float(brightTex.height)
        for i in 0..<3 {
            let r = 1 + Float(i) * 1.6
            var dirH = SIMD2<Float>(r / bw, 0)
            var dirV = SIMD2<Float>(0, r / bh)
            let src = bloomSrc
            quadPass(blurA, blurPipe) { e in
                e.setFragmentTexture(src, index: 0)
                e.setFragmentBytes(&dirH, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            }
            quadPass(blurB, blurPipe) { e in
                e.setFragmentTexture(blurA, index: 0)
                e.setFragmentBytes(&dirV, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            }
            bloomSrc = blurB
        }

        // --- defocus image: two gaussian passes over the whole scene --------
        var dofSrc = sceneTex
        for i in 0..<2 {
            let r = 1.4 + Float(i) * 2.2
            var dirH = SIMD2<Float>(r / Float(dofA.width), 0)
            var dirV = SIMD2<Float>(0, r / Float(dofB.height))
            let src = dofSrc
            quadPass(dofA, blurPipe) { e in
                e.setFragmentTexture(src, index: 0)
                e.setFragmentBytes(&dirH, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            }
            quadPass(dofB, blurPipe) { e in
                e.setFragmentTexture(dofA, index: 0)
                e.setFragmentBytes(&dirV, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            }
            dofSrc = dofB
        }

        // --- grade, straight into the drawable ------------------------------
        let cd = MTLRenderPassDescriptor()
        cd.colorAttachments[0].texture = drawable.texture
        cd.colorAttachments[0].loadAction = .dontCare
        cd.colorAttachments[0].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: cd) {
            e.setRenderPipelineState(compPipe)
            e.setFragmentTexture(sceneTex, index: 0)
            e.setFragmentTexture(bloomSrc, index: 1)
            e.setFragmentTexture(dofB, index: 2)
            e.setFragmentTexture(zTex, index: 3)
            e.setFragmentBytes(&grade, length: MemoryLayout<CanalGradeUniforms>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()
    }
}
