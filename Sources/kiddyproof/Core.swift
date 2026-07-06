import AppKit

// ============================================================================
// Core value types shared by the effects system.
// Threading model (from the adversarial design pass):
//  - Tap thread: only pushes InputEvent value types into KidModeState's ring +
//    bumps heartbeat. Never touches scenes/pools/AppKit.
//  - Render thread (CADisplayLink, main): drains once/frame, routes to the
//    active scene, advances simulation, draws. Single owner — no locks here.
// ============================================================================

enum MouseButton { case left, right, other }

// A discrete input event copied out of the tap callback. Continuous mouse motion
// is NOT sent as events (it would flood the ring); the renderer reads the
// integrated virtualCursor + cursorSeq each frame instead.
struct InputEvent {
    enum Kind {
        case key(String)
        case click(NSPoint, MouseButton)
        case scroll(Double)
    }
    let kind: Kind
    let time: TimeInterval
}

// Which always-on lane an event drives within a scene.
enum Channel: Int, CaseIterable { case keys, clicks, move, scroll, background, cursor }

// ---------------------------------------------------------------------------
// Tiny deterministic RNG (SplitMix64) — no Math.random reliance, seedable per
// effect so behavior is reproducible and allocation-free.
// ---------------------------------------------------------------------------
struct RNG {
    var state: UInt64
    init(seed: UInt64) { state = seed != 0 ? seed : 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) * (1.0 / 9007199254740992.0) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

// ---------------------------------------------------------------------------
// Palette: a small fixed set of colors per scene so particle draws batch by
// color index (one fillPath per color, regardless of particle count).
// ---------------------------------------------------------------------------
// Shared device RGB color space — reused everywhere instead of recreating per gradient.
let sharedRGB = CGColorSpaceCreateDeviceRGB()

@inline(__always) func blendColor(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
    return NSColor(srgbRed: x.redComponent * (1 - t) + y.redComponent * t,
                   green: x.greenComponent * (1 - t) + y.greenComponent * t,
                   blue: x.blueComponent * (1 - t) + y.blueComponent * t, alpha: 1)
}

// A soft glow sprite that reads on ANY background: a bright (near-white) core, the
// scene color, then a soft DARK halo, fading to clear. Drawn with NORMAL blend, the
// bright core shows on dark wallpaper and the dark halo gives contrast on light
// wallpaper — so no dimming veil is needed. Built once per color.
func softContrastSprite(_ color: NSColor, px: Int = 96) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sharedRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = CGPoint(x: px / 2, y: px / 2)
    // Core is the SATURATED color (medium luminance → visible on white AND black), only
    // slightly brightened. A strong dark halo gives separation on light wallpaper; the
    // additive glow pass (drawn separately) supplies the bloom on dark wallpaper.
    // A soft but DEFINED colored body (visible as a disc on white) ringed by a crisp dark
    // rim (separation on white), fading to clear. On dark the rim disappears and the body
    // glows. Five stops give body + rim instead of a single wash.
    let core = blendColor(color, .white, 0.35)
    let cols = [core.withAlphaComponent(0.95).cgColor,
                color.withAlphaComponent(0.88).cgColor,
                color.withAlphaComponent(0.6).cgColor,
                NSColor.black.withAlphaComponent(0.72).cgColor,   // crisp dark rim
                NSColor.black.withAlphaComponent(0).cgColor] as CFArray
    let g = CGGradient(colorsSpace: sharedRGB, colors: cols, locations: [0, 0.42, 0.68, 0.83, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(px) / 2, options: [])
    return ctx.makeImage()!
}

// Stroke a path so it reads on light AND dark wallpaper: a wider dark casing (contrast on
// light) beneath a lighter core (visible on dark) — the line equivalent of the contrast
// sprite. Pass the same CGPath; it's added twice.
func strokeContrast(_ ctx: CGContext, _ path: CGPath, width: CGFloat, alpha: CGFloat,
                    coreColor: NSColor = NSColor(srgbRed: 0.9, green: 0.94, blue: 1, alpha: 1)) {
    guard alpha > 0.01 else { return }
    ctx.setBlendMode(.normal)
    ctx.setLineCap(.round)
    ctx.addPath(path)
    ctx.setLineWidth(width + 1.8)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(min(1, alpha * 0.55)).cgColor)
    ctx.strokePath()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setStrokeColor(coreColor.withAlphaComponent(min(1, alpha)).cgColor)
    ctx.strokePath()
}

// An "ink" stamp: a soft round dab with a fairly solid center fading to clear — overlap
// many of these along a path to paint a flowing brush stroke. Cache one per color and
// blit them (cheap) to build strokes, blooms, and brushy arcs.
func inkSprite(_ color: NSColor, px: Int = 48) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sharedRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = CGPoint(x: px / 2, y: px / 2)
    let cols = [color.withAlphaComponent(0.95).cgColor,
                color.withAlphaComponent(0.85).cgColor,
                color.withAlphaComponent(0).cgColor] as CFArray
    let g = CGGradient(colorsSpace: sharedRGB, colors: cols, locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(px) / 2, options: [])
    return ctx.makeImage()!
}

// Paint a soft ink ring: overlapping dabs around a circle with an organic, per-ring
// wobble so it reads as bleeding ink rather than a clean stroke. The caller sets blend
// mode + alpha and passes a cached colored stamp; `seed` varies the wobble per ring.
func inkRing(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, radius: CGFloat, dab: CGFloat,
             stamp: CGImage, seed: CGFloat, wobble: CGFloat = 0.05) {
    // Space dabs at a fraction of their size so they overlap into a continuous, bleeding
    // band rather than a string of beads. Two low-frequency wobbles give an organic,
    // hand-painted edge without scattering the dabs.
    let n = max(12, min(240, Int(radius * 6.2832 / max(3, dab * 0.55))))
    for k in 0..<n {
        let ang = CGFloat(k) / CGFloat(n) * 2 * .pi
        let rr = radius + (sin(ang * 3 + seed) + 0.5 * sin(ang * 7 + seed * 2.3)) * radius * wobble
        let x = cx + cos(ang) * rr, y = cy + sin(ang) * rr
        ctx.draw(stamp, in: CGRect(x: x - dab, y: y - dab, width: dab * 2, height: dab * 2))
    }
}

// A pure colored glow → clear, for an ADDITIVE bloom pass (extra glow on dark, washes
// out harmlessly on light).
func softGlowSprite(_ color: NSColor, px: Int = 96) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sharedRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = CGPoint(x: px / 2, y: px / 2)
    let cols = [color.withAlphaComponent(0.9).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
    let g = CGGradient(colorsSpace: sharedRGB, colors: cols, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(px) / 2, options: [])
    return ctx.makeImage()!
}

struct Palette {
    let colors: [CGColor]          // indexable by UInt8 colorIndex
    init(_ hexes: [(CGFloat, CGFloat, CGFloat)]) {
        colors = hexes.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1).cgColor }
    }
}

// Per-frame read-only environment handed to a scene.
struct EffectContext {
    let dt: CGFloat
    let now: TimeInterval
    let intensity: CGFloat        // 0…1, already capped by the settings ceiling
    let bounds: CGRect            // simulation canvas (primary screen frame, global coords)
    let cursor: NSPoint           // virtual cursor, global screen coords (y-up)
    let cursorVel: NSPoint        // px/s, render-derived
    let leftButtonDown: Bool      // is the (virtual) left button currently held
    let audio: KidAudio?          // long-lived; strong ref in a short-lived ctx is fine
    let background: BackgroundLuminance?   // adaptive contrast map (opt-in), else nil
    let fallbackLightness: CGFloat         // appearance/KP_TESTBG proxy when no map

    // Background lightness behind a global point: 0 = dark wallpaper, 1 = white.
    // With the opt-in adaptive-contrast map this is the REAL pixels behind the
    // element; otherwise it's one session-wide proxy value.
    func lightness(at p: NSPoint) -> CGFloat {
        background?.luma(at: p) ?? fallbackLightness
    }
    // 0 on dark backgrounds → 1 on light: the standard blend weight for choosing
    // between a scene's glow rendering and its bold-ink rendering.
    func inkWeight(at p: NSPoint) -> CGFloat {
        let l = lightness(at: p)
        let t = min(1, max(0, (l - 0.42) / 0.28))
        return t * t * (3 - 2 * t)
    }
}

// Scene-side ink weight for draw() passes (scenes cache the map + fallback from the
// last update(), since draw() has no context). Same curve as EffectContext.inkWeight.
func inkWeight(_ map: BackgroundLuminance?, _ fallback: CGFloat, _ p: NSPoint) -> CGFloat {
    let l = map?.luma(at: p) ?? fallback
    let t = min(1, max(0, (l - 0.42) / 0.28))
    return t * t * (3 - 2 * t)
}

// live = made the cut, in the rotation (parents can disable individual scenes);
// archived = built but scrapped (still previewable via KP_SCENE, never cycled).
enum SceneCategory { case live, archived }

// How a scene turns input rate into the 0…1 intensity that modulates its effects.
// Calm scenes cap LOW with slow attack/decay so a frantic mash can never become busy;
// energetic scenes amplify quickly.
struct Reactivity {
    let ceiling: CGFloat      // max intensity this scene will ever reach
    let attackTau: CGFloat    // rise time-constant (smaller = faster)
    let decayTau: CGFloat     // fall time-constant
    let gain: CGFloat         // how strongly input rate pushes toward the ceiling
    static let calm = Reactivity(ceiling: 0.35, attackTau: 0.6, decayTau: 1.6, gain: 0.5)
    static let energetic = Reactivity(ceiling: 1.0, attackTau: 0.08, decayTau: 0.6, gain: 1.0)
}

// The switchable unit. A scene owns its channels' effects + look + lifecycle.
protocol Scene: AnyObject {
    var name: String { get }
    var category: SceneCategory { get }
    var reactivity: Reactivity { get }
    var skin: CursorSkin { get }
    // CORE PREMISE: the overlay is TRANSPARENT — the child sees the parent's real screen.
    // `veil` is only a light dusk dimming (0…~0.4 black) so glowing effects stay visible
    // on any wallpaper. Scenes draw EFFECTS ONLY, never an opaque background.
    var veil: CGFloat { get }
    var draining: Bool { get set }     // true during a crossfade-out: ignore new events
    var audioSwell: CGFloat { get }    // 0…1 continuous audio drive (e.g. black hole suction)
    func handle(_ event: InputEvent, _ ctx: EffectContext)
    func update(_ ctx: EffectContext)
    func draw(into ctx: CGContext, bounds: CGRect, origin: CGPoint)
    func liveCount() -> Int
    func reset()                       // clear all state for reuse (no dealloc)
}

extension Scene { var audioSwell: CGFloat { 0 } }   // most scenes have no continuous audio drive

// ---------------------------------------------------------------------------
// MashMeter: the intensity modulator. Smoothed 0…1 from events/sec with an
// attack/decay envelope; capped by the settings ceiling. Never switches scenes.
// ---------------------------------------------------------------------------
final class MashMeter {
    private var lastHeartbeat: UInt64 = 0
    private var value: CGFloat = 0
    private(set) var intensity: CGFloat = 0

    // `reactivity` is the active scene's profile; `ceilingMult` is the parent's global
    // Calm/Balanced/Wild setting. The scene's own ceiling is the hard cap, so a calm
    // scene stays calm regardless of how hard the kid mashes.
    func update(heartbeat: UInt64, dt: CGFloat, reactivity: Reactivity, ceilingMult: CGFloat) {
        // First sample after a reset only records the baseline: the heartbeat kept
        // counting pass-through events between sessions, and treating that whole
        // idle delta as one frame of input opened every session with a phantom flare.
        if !hasBaseline { hasBaseline = true; lastHeartbeat = heartbeat; return }
        let delta = heartbeat >= lastHeartbeat ? heartbeat - lastHeartbeat : 0
        lastHeartbeat = heartbeat
        let rate = dt > 0 ? CGFloat(delta) / dt : 0                 // events/sec
        let target = min(1, (rate / 25.0) * reactivity.gain)        // ~25/s = full input
        let tau = target > value ? reactivity.attackTau : reactivity.decayTau
        value += (target - value) * (1 - exp(-dt / tau))
        intensity = min(value, reactivity.ceiling * ceilingMult)
    }

    private var hasBaseline = false
    func reset() { value = 0; intensity = 0; hasBaseline = false }
}

// Small vector helpers (kept local; CGPoint math reads cleaner than SIMD here).
@inline(__always) func + (a: NSPoint, b: NSPoint) -> NSPoint { NSPoint(x: a.x + b.x, y: a.y + b.y) }
@inline(__always) func - (a: NSPoint, b: NSPoint) -> NSPoint { NSPoint(x: a.x - b.x, y: a.y - b.y) }
@inline(__always) func * (a: NSPoint, s: CGFloat) -> NSPoint { NSPoint(x: a.x * s, y: a.y * s) }
@inline(__always) func hypot2(_ p: NSPoint) -> CGFloat { p.x * p.x + p.y * p.y }
