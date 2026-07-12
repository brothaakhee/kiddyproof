import AppKit
// Silhouette IoU: threshold both images to binary masks, crop to content
// bbox, resize to a common grid, measure overlap.
func mask(_ path: String) -> [[Bool]]? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let d = ctx.data!.bindMemory(to: UInt8.self, capacity: w*h*4)
    var m = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
    for y in 0..<h { for x in 0..<w {
        let i = (y*w + x)*4
        m[y][x] = d[i] < 110 && d[i+1] < 110 && d[i+2] < 110
    }}
    return m
}
// Erase near-full-width horizontal runs (the lab's ground line).
func eraseGround(_ m: inout [[Bool]]) {
    let w = m[0].count
    for y in 0..<m.count {
        let dark = m[y].filter { $0 }.count
        if Double(dark) > Double(w) * 0.5 { for x in 0..<w { m[y][x] = false } }
    }
}
// Keep only the largest connected component (drops the ground line/laser).
func largestComponent(_ m: [[Bool]]) -> [[Bool]] {
    let h = m.count, w = m[0].count
    var labels = [[Int]](repeating: [Int](repeating: 0, count: w), count: h)
    var best = 0, bestLabel = 0, next = 1
    for sy in 0..<h { for sx in 0..<w where m[sy][sx] && labels[sy][sx] == 0 {
        var stack = [(sx, sy)], count = 0
        labels[sy][sx] = next
        while let (x, y) = stack.popLast() {
            count += 1
            for (dx, dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                let nx = x+dx, ny = y+dy
                if nx >= 0, nx < w, ny >= 0, ny < h, m[ny][nx], labels[ny][nx] == 0 {
                    labels[ny][nx] = next; stack.append((nx, ny))
                }
            }
        }
        if count > best { best = count; bestLabel = next }
        next += 1
    }}
    var out = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
    for y in 0..<h { for x in 0..<w { out[y][x] = labels[y][x] == bestLabel } }
    return out
}
func bbox(_ m: [[Bool]]) -> (Int, Int, Int, Int) {
    var minX = m[0].count, maxX = 0, minY = m.count, maxY = 0
    for y in 0..<m.count { for x in 0..<m[0].count where m[y][x] {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }}
    return (minX, minY, maxX, maxY)
}
func norm(_ m: [[Bool]], _ n: Int) -> [[Bool]] {
    let (x0, y0, x1, y1) = bbox(m)
    let bw = x1 - x0 + 1, bh = y1 - y0 + 1
    var out = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)
    for y in 0..<n { for x in 0..<n {
        let sx = x0 + x * bw / n, sy = y0 + y * bh / n
        out[y][x] = m[sy][sx]
    }}
    return out
}
var ma = mask(CommandLine.arguments[1])!; eraseGround(&ma)
let a = norm(largestComponent(ma), 220)
var mb = mask(CommandLine.arguments[2])!; eraseGround(&mb)
let b = norm(largestComponent(mb), 220)
func iou(_ a: [[Bool]], _ b: [[Bool]]) -> (Double, Int, Int) {
    var i = 0, u = 0
    for y in 0..<220 { for x in 0..<220 {
        if a[y][x] && b[y][x] { i += 1 }
        if a[y][x] || b[y][x] { u += 1 }
    }}
    return (Double(i)/Double(u), i, u)
}
// Facing is arbitrary (she looks at the laser) — take the better mirror.
let bFlip = b.map { Array($0.reversed()) }
let straight = iou(a, b), mirrored = iou(a, bFlip)
let bestB = mirrored.0 > straight.0 ? bFlip : b
let (v, inter, union_) = mirrored.0 > straight.0 ? mirrored : straight
_ = v
let bDraw = bestB
print(String(format: "IoU: %.3f  (intersection %d / union %d)", Double(inter)/Double(union_), inter, union_))
// Diff visualization: black = both, red = reference only, blue = render only.
if CommandLine.arguments.count > 3 {
    let n = 220
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n*4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
    for y in 0..<n { for x in 0..<n {
        var c: CGColor? = nil
        if a[y][x] && bDraw[y][x] { c = CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1) }
        else if a[y][x] { c = CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1) }
        else if bDraw[y][x] { c = CGColor(red: 0.2, green: 0.4, blue: 0.95, alpha: 1) }
        if let c = c { ctx.setFillColor(c); ctx.fill(CGRect(x: x, y: n-1-y, width: 1, height: 1)) }
    }}
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
}
