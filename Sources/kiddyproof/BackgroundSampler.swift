import AppKit
import ScreenCaptureKit

// Opt-in adaptive contrast. With the parent's Screen Recording permission we take ONE
// low-resolution screenshot per display at arm time (the desktop is input-frozen for
// the whole session, so a single capture stays true — the architecture's
// "capture-once-and-freeze") and reduce it to a small luminance grid. Scenes sample
// it PER ELEMENT, so a star over a white browser renders as bold ink while its
// neighbor over a dark terminal glows — premium contrast everywhere at zero per-frame
// cost. No permission / capture failure → nil → scenes fall back to the system-
// appearance proxy. Never captures when KP_TESTBG paints over the real desktop.
struct BackgroundLuminance {
    struct DisplayGrid {
        let frame: NSRect        // global y-up screen coords
        let cols: Int
        let rows: Int            // row 0 = TOP of the screen
        let luma: [CGFloat]      // 0 = black … 1 = white
    }
    let grids: [DisplayGrid]

    // Perceptual background lightness at a global (y-up) point, or nil off-grid.
    func luma(at p: NSPoint) -> CGFloat? {
        for g in grids where NSPointInRect(p, g.frame) {
            let u = (p.x - g.frame.minX) / g.frame.width
            let v = (p.y - g.frame.minY) / g.frame.height
            let cx = min(g.cols - 1, max(0, Int(u * CGFloat(g.cols))))
            let cy = min(g.rows - 1, max(0, Int((1 - v) * CGFloat(g.rows))))
            return g.luma[cy * g.cols + cx]
        }
        return nil
    }
}

enum BackgroundSampler {
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    // Triggers the one-time system prompt / adds the app to the Screen Recording list.
    // macOS applies the grant only to a freshly launched app — callers show guidance.
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    // Completion is called exactly once, on an arbitrary queue, with nil on ANY failure.
    static func capture(completion: @escaping (BackgroundLuminance?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content = content, error == nil else {
                NSLog("[kiddyproof] adaptive contrast: shareable content failed (\(String(describing: error)))")
                completion(nil)
                return
            }
            // NSScreen is a main-thread API: snapshot the id->frame map there, then
            // do the captures off-main with the plain values.
            DispatchQueue.main.async {
                var screenFrames: [CGDirectDisplayID: NSRect] = [:]
                for sc in NSScreen.screens {
                    if let id = sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                        screenFrames[id] = sc.frame
                    }
                }
                Task {
                    var grids: [BackgroundLuminance.DisplayGrid] = []
                    for display in content.displays {
                        guard let frame = screenFrames[display.displayID] else { continue }
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let cfg = SCStreamConfiguration()
                        cfg.width = 96
                        cfg.height = 60
                        cfg.showsCursor = false
                        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
                           let grid = lumaGrid(from: img, frame: frame) {
                            grids.append(grid)
                        }
                    }
                    NSLog("[kiddyproof] adaptive contrast: sampled \(grids.count) display(s).")
                    completion(grids.isEmpty ? nil : BackgroundLuminance(grids: grids))
                }
            }
        }
    }

    // Reduce a screenshot to a cols×rows grid of perceptual luminance.
    private static func lumaGrid(from image: CGImage, frame: NSRect) -> BackgroundLuminance.DisplayGrid? {
        let cols = 32, rows = 20
        guard let ctx = CGContext(data: nil, width: cols, height: rows,
                                  bitsPerComponent: 8, bytesPerRow: cols * 4,
                                  space: sharedRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: cols * rows * 4)
        var luma = [CGFloat](repeating: 0, count: cols * rows)
        for i in 0..<(cols * rows) {
            let r = CGFloat(bytes[i * 4]) / 255
            let g = CGFloat(bytes[i * 4 + 1]) / 255
            let b = CGFloat(bytes[i * 4 + 2]) / 255
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        // Bitmap-context memory is top-down (row 0 = top scanline) even though CG
        // drawing coordinates are bottom-up, so `luma` row 0 is already the top of the
        // screen — exactly the grid convention.
        return BackgroundLuminance.DisplayGrid(frame: frame, cols: cols, rows: rows, luma: luma)
    }
}
