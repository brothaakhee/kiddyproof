import XCTest
@testable import CanalSim

// The same picture the reference harness prints, so a port change can be eyeballed
// against it rather than argued about:
//
//   $ SEED=3 node test/margin.mjs '{}'      (in the canalisation repo)
//   $ swift test --filter testDumpSilhouette
//
// '#' is blade, '-' the midrib, '*' a convergence point (a tooth).
final class MarginDumpTests: XCTestCase {

    func testDumpSilhouette() {
        let m = Margin(AuxinParams(), MarginOptions(), seed: 3)
        var s = 0
        while !m.mature && s < 4000 { m.step(1); s += 1 }

        print("{\"steps\":\(s),\"pts\":\(m.F.n),\"teeth\":\(m.teeth.count)," +
              "\"aspect\":\(String(format: "%.2f", m.aspect))," +
              "\"len\":\(String(format: "%.2f", m.length))}")

        let W = 74, H = 27
        var g = [[Character]](repeating: [Character](repeating: " ", count: W), count: H)
        let mid = Float(H - 1) / 2
        for k in 0..<W {
            let u = Float(k) / Float(W - 1)
            let l = m.half(u, -1) / m.aspect, r = m.half(u, 1) / m.aspect
            for y in 0..<H {
                let v = (Float(y) - mid) / mid
                if v < 0 && -v <= l { g[y][k] = "#" }
                if v > 0 && v <= r { g[y][k] = "#" }
                if abs(v) < 0.04 { g[y][k] = "-" }
            }
        }
        for t in m.teeth {
            let k = Int((t.u * Float(W - 1)).rounded())
            let y = Int((mid + (t.v / m.aspect) * mid).rounded())
            if k >= 0 && k < W && y >= 0 && y < H { g[y][k] = "*" }
        }
        print(g.map { String($0) }.joined(separator: "\n"))
    }

    // Counterpart to `node test/phyllo.mjs`, for the same side-by-side reading.
    func testDumpPhyllotaxis() {
        let m = Meristem(AuxinParams(), MeristemOptions(), seed: 7)
        for _ in 0..<2600 { m.step(1) }
        var sum: Float = 0, mx: Float = 0
        for i in 0..<m.F.n { sum += m.F.a[i]; if m.F.a[i] > mx { mx = m.F.a[i] } }
        let st = m.divergenceStats(window: 60)
        print("{\"cells\":\(m.F.n),\"primordiaTotal\":\(m.divergence.count + 1)," +
              "\"live\":\(m.primordia.count),\"plastochron\":\(String(format: "%.2f", m.plastochron))," +
              "\"auxin\":{\"mean\":\(String(format: "%.2f", sum / Float(m.F.n)))," +
              "\"max\":\(String(format: "%.2f", mx))}," +
              "\"divergence\":{\"mean\":\(String(format: "%.2f", st?.mean ?? 0))," +
              "\"sd\":\(String(format: "%.2f", st?.sd ?? 0)),\"n\":\(st?.n ?? 0)," +
              "\"handed\":\"\(st?.counterClockwise == true ? "counter-clockwise" : "clockwise")\"}}")
    }
}
