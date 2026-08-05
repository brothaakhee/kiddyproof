import Foundation
import simd

// ---------------------------------------------------------------------------
// Scalar helpers + the deterministic PRNG, ported from src/00_math.js.
//
// Everything downstream of a species seed must be reproducible: the same seed
// has to grow the same plant, down to the last vein segment, or the close-up
// replay and the tests stop meaning anything. So the PRNG is mulberry32 with
// the exact same integer mixing as the original — not Swift's SystemRandom, and
// not the project's other RNG (Core.swift), whose stream differs.
// ---------------------------------------------------------------------------

@inline(__always) func canalClamp(_ v: Float, _ a: Float, _ b: Float) -> Float {
    v < a ? a : (v > b ? b : v)
}
@inline(__always) func canalLerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func canalSmoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = canalClamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}
public let CANAL_TAU: Float = .pi * 2

// Signed smallest difference between two angles, in (-pi, pi].
@inline(__always) func angDelta(_ a: Float, _ b: Float) -> Float {
    var d = (b - a).truncatingRemainder(dividingBy: CANAL_TAU)
    if d > .pi { d -= CANAL_TAU }
    if d <= -.pi { d += CANAL_TAU }
    return d
}

// mulberry32 — bit-exact with the JS original (Math.imul is a 32-bit multiply
// that wraps, which is `&*` on UInt32 here).
public struct Mulberry32 {
    private var t: UInt32
    init(seed: UInt32) { t = seed }

    mutating func next() -> Float {
        t = t &+ 0x6d2b79f5
        var r = (t ^ (t >> 15)) &* (1 | t)
        r = (r &+ ((r ^ (r >> 7)) &* (61 | r))) ^ r
        return Float((r ^ (r >> 14)) >> 0) / 4294967296.0
    }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : min(n - 1, Int(next() * Float(n))) }
}

// ---------------------------------------------------------------------------
// Camera matrices. The originals (m4perspective/m4lookAt) target WebGL's
// -1…1 clip depth; Metal's is 0…1, so the projection is the Metal form rather
// than a literal port. Column-major either way.
// ---------------------------------------------------------------------------

public func canalPerspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
    let f = 1 / tan(fovY / 2)
    return float4x4(
        SIMD4<Float>(f / aspect, 0, 0, 0),
        SIMD4<Float>(0, f, 0, 0),
        SIMD4<Float>(0, 0, far / (near - far), -1),
        SIMD4<Float>(0, 0, (far * near) / (near - far), 0)
    )
}

public func canalLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
    let z = simd_normalize(eye - center)
    let x = simd_normalize(simd_cross(up, z))
    let y = simd_cross(z, x)
    return float4x4(
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
    )
}

// Rodrigues rotation of `v` around unit axis `k` by angle `t`.
@inline(__always)
public func rotAxis(_ v: SIMD3<Float>, _ k: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    let c = cos(t), s = sin(t)
    return v * c + simd_cross(k, v) * s + k * (simd_dot(k, v) * (1 - c))
}
