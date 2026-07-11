import AppKit

// KIDDY, 8-BIT — authored pixel-art sprite frames (not a scaled-down vector cat):
// a coarse grid, a tight palette, crisp integer scaling with interpolation OFF,
// and discrete animation frames chosen by the shared KiddyCat brain (gait phase,
// states, blink). The polish rules are the classic ones: 1px outline on the
// EXTERIOR silhouette only, a 2x2 eye with a single shine pixel, restrained
// interior detail, readable silhouette at a glance.
enum KiddyCatPixel {

    // Palette: '.'=clear  K=outline  O=orange  S=shade  C=cream  P=pink
    //          W=eye shine  B=pupil
    private static let palette: [Character: NSColor] = [
        "K": NSColor(srgbRed: 0.20, green: 0.11, blue: 0.08, alpha: 1),
        "O": NSColor(srgbRed: 0.96, green: 0.60, blue: 0.24, alpha: 1),
        "S": NSColor(srgbRed: 0.78, green: 0.44, blue: 0.16, alpha: 1),
        "C": NSColor(srgbRed: 1.00, green: 0.94, blue: 0.83, alpha: 1),
        "P": NSColor(srgbRed: 1.00, green: 0.60, blue: 0.62, alpha: 1),
        "W": NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        "B": NSColor(srgbRed: 0.13, green: 0.10, blue: 0.10, alpha: 1),
    ]

    // ------------------------------------------------------------------
    // FRAMES — 34 wide x 24 tall, cat faces RIGHT, ground = bottom row.
    // ------------------------------------------------------------------

    // Standing / idle: tail curled up behind, all four feet planted.
    static let idle1 = [
        ".................KK......KK.......",
        "................KOOK....KOOK......",
        "................KOPOK..KOPOK......",
        "...............KOOOOOOOOOOOOK.....",
        "..............KOOOOOOOOOOOOOOK....",
        "..............KOOOOOOOOOOOOOOK....",
        ".KK...........KOOOOOOOOBWOOOOK....",
        "KOOK..........KOOOOOOOOBBOOOOK....",
        "KOOK..........KOOOOOOOOOOCCCPK....",
        ".KOOK.........KOOOOOOOOOCCCCCK....",
        ".KOOK....KKKKKKOOOOOOOOOCCCCK.....",
        "..KOOK..KOOOOOOOOOOOOOOOCCCK......",
        "...KOOKKOOOOOOOOOOOOOOOOOOK.......",
        "....KOOKOOOOOOOOOOOOOOOOOOK.......",
        ".......KOOOOOOOOOOOOOOOOOOK.......",
        ".......KOOOOOOOOOOOOOOOOOOK.......",
        ".......KOOOOOOOOOOOOOOOOOOK.......",
        ".......KOOKKKKKKKKKKKKOOKKK.......",
        ".......KOOK.SS...SS..KOOK.........",
        ".......KOOK.SS...SS..KOOK.........",
        ".......KOOK.SS...SS..KOOK.........",
        ".......KOOK.SS...SS..KOOK.........",
        ".......KKKK.KK...KK..KKKK.........",
    ]

    // Idle blink: eye closed (shine gone, pupil row becomes a dark lash line).
    static let idle2: [String] = { blink(idle1) }()

    private static func blink(_ frame: [String]) -> [String] {
        frame.map { row in
            row.replacingOccurrences(of: "BW", with: "OO")
               .replacingOccurrences(of: "BB", with: "KK")
        }
    }

    // Walk cycle, 4 frames: contact / passing / contact(opposite) / passing.
    // Far legs are shade-colored and 3px so depth reads without clutter.
    private static let walkBody: [String] = Array(idle1[0...16]) + [
        ".......KKKKKKKKKKKKKKKKKKKK.......",
    ]

    static let walk1: [String] = walkBody + [
        "....KOOK..SS......SS..KOOK........",
        "....KOOK..SS......SS..KOOK........",
        "....KOOK..SS......SS..KOOK........",
        "....KOOK..SS......SS..KOOK........",
        "....KKKK..KK......KK..KKKK........",
    ]

    static let walk2: [String] = walkBody + [
        "........KOOK.SS..SS..KOOK.........",
        "........KOOK.SS..SS..KOOK.........",
        "........KOOK.SS..SS..KOOK.........",
        "........KOOK.SS..SS..KOOK.........",
        "........KKKK.KK..KK..KKKK.........",
    ]

    static let walk3: [String] = walkBody + [
        "......SS..KOOK....KOOK..SS........",
        "......SS..KOOK....KOOK..SS........",
        "......SS..KOOK....KOOK..SS........",
        "......SS..KOOK....KOOK..SS........",
        "......KK..KKKK....KKKK..KK........",
    ]

    static let walk4: [String] = walkBody + [
        "........KOOK.......KOOK...........",
        "........KOOK.......KOOK...........",
        "........KOOK.......KOOK...........",
        "........KOOK.......KOOK...........",
        "........KKKK.......KKKK...........",
    ]

    // Sit: upright, haunch mound, front legs straight, tail curled at the base.
    static let sit1 = [
        ".................KK......KK.......",
        "................KOOK....KOOK......",
        "................KOPOK..KOPOK......",
        "...............KOOOOOOOOOOOOK.....",
        "..............KOOOOOOOOOOOOOOK....",
        "..............KOOOOOOOOOOOOOOK....",
        "..............KOOOOOOOOBWOOOOK....",
        "..............KOOOOOOOOBBOOOOK....",
        "..............KOOOOOOOOOOCCCPK....",
        "..............KOOOOOOOOOCCCCCK....",
        "...............KOOOOOOOOCCCCK.....",
        "................KOOOOOOOOCCK......",
        "..............KOOOOOOOOOOOK.......",
        ".............KOOOOOOOOOOOOK.......",
        "............KOOOOOOOOOOOOOK.......",
        "...........KOOOOOOOOOOOOOOK.......",
        "..........KOOOOOOOOOOOOOOOK.......",
        "..........KOOOOOOOOOOOOOOOK.......",
        "..........KOOOOOOOOOOOOOOOK.......",
        "..........KOOOOOOOOOOOOOOOK.......",
        "..........KOOOOOOOOOKKOOKKK.......",
        ".....KKKKKKOOOOOOOOK.KOOK.........",
        "....KOOOOOKOOOOOOOOK.KOOK.........",
        "....KKKKKKKKKKKKKKKK.KKKK.........",
    ]

    static let sit2: [String] = { blink(sit1) }()

    // Stalk: body long and LOW, head thrust forward, tail flat behind.
    static let stalk1 = [
        "..................................",
        "..................................",
        "..................................",
        "..................................",
        "..................................",
        "..................................",
        "....................KK......KK....",
        "...................KOOK....KOOK...",
        "...................KOPOK..KOPOK...",
        "..................KOOOOOOOOOOOOK..",
        ".................KOOOOOOOOOOOOOOK.",
        ".................KOOOOOOOOOOOOOOK.",
        ".................KOOOOOOOOBWOOOOK.",
        ".................KOOOOOOOOBBOOOOK.",
        ".................KOOOOOOOOOOCCCPK.",
        "........KKKKKKKKKOOOOOOOOOCCCCCK..",
        "KKKKKK..KOOOOOOOOOOOOOOOOOOCCCCK..",
        "KOOOOOKKOOOOOOOOOOOOOOOOOOOOCCK...",
        "KKKKKKOOOOOOOOOOOOOOOOOOOOOOKK....",
        ".....KKOOOOOOOOOOOOOOOOOOOOKK.....",
        ".......KKKKKKKKKKKKKKKKKKKK.......",
        ".....KOOK..KOOK....KOOK..KOOK.....",
        ".....KOOK..KOOK....KOOK..KOOK.....",
        ".....KKKK..KKKK....KKKK..KKKK.....",
    ]

    static let stalk2: [String] = {
        var f = stalk1
        f[21] = "...KOOK..KOOK....KOOK..KOOK......."
        f[22] = "...KOOK..KOOK....KOOK..KOOK......."
        f[23] = "...KKKK..KKKK....KKKK..KKKK......."
        return f
    }()

    // Pounce (airborne): a bounding arc up-and-forward, paws tucked,
    // tail streaming behind.
    static let pounce = [
        ".......................KK.....KK..",
        "......................KOOK...KOOK.",
        "......................KOPOK.KOPOK.",
        ".....................KOOOOOOOOOOOK",
        "....................KOOOOOOOOOOOOK",
        "....................KOOOOOOOBWOOOK",
        "....................KOOOOOOOBBOOOK",
        "....................KOOOOOOOOOCCPK",
        ".....................KOOOOOOOCCCCK",
        "................KKOOOOOOOOOKKOOOK.",
        "..............KKOOOOOOOOOK...KOOK.",
        "............KKOOOOOOOOOK.....KKKK.",
        ".KK.......KKOOOOOOOOOK............",
        ".KOOK...KKOOOOOOOOOK..............",
        "..KOOK.KOOOOOOOOK.................",
        "....KKKOOOOOOOOK..................",
        "......KOOK..KOOK..................",
        "......KKKK..KKKK..................",
        "..................................",
        "..................................",
        "..................................",
        "..................................",
        "..................................",
        "..................................",
    ]

    // Stretch: play-bow — rump and tail high on the left, chest low,
    // front legs extended, head low at the front.
    static let stretch = [
        "....KK............................",
        "...KOOK...........................",
        "..KOOK............................",
        "..KOOK............................",
        ".KOOK.............................",
        ".KOOK.............................",
        "..KOOKKKK.........................",
        "...KOOOOOKK.......................",
        "...KOOOOOOOKK.....................",
        "....KOOOOOOOOKK...................",
        "....KOOOOOOOOOOKK......KK.....KK..",
        "....KOOOOOOOOOOOOKKK..KOOK...KOOK.",
        "....KOOKKOOOOOOOOOOKK..KOPOK.KOPOK",
        "....KOOK.KOOOOOOOOOOOKOOOOOOOOOOK.",
        "....KOOK...KOOOOOOOOOOOOOOOOOOOOOK",
        "....KOOK....KOOOOOOOOOOOOOBWOOOOOK",
        "....KOOK....KOOOOOOOOOOOOOBBOOOOOK",
        "....KOOK.....KOOOOOOOOOOOOOOOCCPK.",
        "....KOOK.....KOOOOOOOOOOOOOCCCCK..",
        "....KOOK......KKKKKKOOOOOOOKKKK...",
        "....KOOK...........KOOK..KOOK.....",
        "....KOOK...........KOOK..KOOK.....",
        "....KOOK...........KOOK..KOOK.....",
        "....KKKK...........KKKK..KKKK.....",
    ]

    // Startle: back arched, tail bottle-brushed straight up, ears up,
    // stiff tiptoe legs.
    static let startle = [
        "...KK.............................",
        "..KOOK............................",
        "..KOOK............................",
        "..KOOK............................",
        "..KOOK............................",
        "..KOOK............................",
        "..KOOK.....KKKKKK.................",
        "..KOOK...KKOOOOOOKK...............",
        "..KOOK..KOOOOOOOOOOK....KK...KK...",
        "..KOOKKOOOOOOOOOOOOK...KOOK.KOOK..",
        "...KKOOOOOOOOOOOOOOKOOOOOOOOOOOOK.",
        "....KOOOOOOOOOOOOOOOOOOOOOOOOOOOK.",
        "....KOOOOOOOOOOOOOOOOOOOOBWOOOOOK.",
        ".....KOOOOOOOOOOOOOOOOOOOBBOOOOOK.",
        ".....KOOOOOOOOOOOOOOOOOOOOOCCCPK..",
        "......KOOOOOOOOOOOOOOOOOOOCCCCK...",
        "......KOOOOOOOOOOOOOOOOOOOOOKK....",
        "......KOOKKKKKKKKKKKKKKKKKOOK.....",
        "......KOOK...............KOOK.....",
        "......KOOK...............KOOK.....",
        "......KOOK...............KOOK.....",
        "......KOOK...............KOOK.....",
        "......KOOK...............KOOK.....",
        "......KKKK...............KKKK.....",
    ]

    // ------------------------------------------------------------------
    // Parsing + cache: one CGImage per frame, built once.
    // ------------------------------------------------------------------

    private static var cache: [String: CGImage] = [:]

    static func image(_ key: String, _ rows: [String]) -> CGImage {
        if let img = cache[key] { return img }
        let h = rows.count
        let w = rows.map { $0.count }.max() ?? 0
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: sharedRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let color = palette[ch] else { continue }
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1))
            }
        }
        let img = ctx.makeImage()!
        cache[key] = img
        return img
    }
}
