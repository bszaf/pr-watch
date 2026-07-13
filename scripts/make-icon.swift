import AppKit

// Renders a 1024×1024 app-icon PNG: a rounded-square gradient tile with a white
// pull-request glyph. Usage: swift make-icon.swift <out.png>

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

/// Recolor the opaque pixels of an image to white (isolated, so only the glyph is tinted).
func tintWhite(_ image: NSImage) -> NSImage {
    let w = Int(image.size.width), h = Int(image.size.height)
    let rep = bitmap(w, h)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    image.draw(in: rect)
    NSColor.white.setFill()
    rect.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    let out = NSImage(size: image.size)
    out.addRepresentation(rep)
    return out
}

let rep = bitmap(Int(size), Int(size))
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

// Rounded-square tile with a diagonal blurple gradient.
let margin = size * 0.085
let tile = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let radius = tile.width * 0.2237
let clip = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
clip.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.60, green: 0.40, blue: 0.98, alpha: 1),   // light purple
    NSColor(srgbRed: 0.35, green: 0.30, blue: 0.85, alpha: 1),   // indigo
])!
gradient.draw(in: tile, angle: -55)

// White pull-request glyph, centered, preserving aspect.
let cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold)
let symbolName = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) != nil
    ? "arrow.triangle.pull" : "arrow.triangle.branch"
if let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
   let sym = base.withSymbolConfiguration(cfg) {
    let white = tintWhite(sym)
    let maxDim = tile.width * 0.58
    let scale = min(maxDim / white.size.width, maxDim / white.size.height)
    let w = white.size.width * scale, h = white.size.height * scale
    white.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode PNG\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
