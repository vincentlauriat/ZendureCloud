// Génère l'AppIcon de ZendureCloud : squircle dégradé bleu nuit → cyan,
// nuage blanc + éclair jaune (SF Symbols), déclinée dans toutes les tailles.
// Usage : swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Marge standard des icônes macOS : le contenu occupe ~80 % du canevas.
    let inset = size * 0.098
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Fond dégradé bleu nuit → cyan (ciel/cloud).
    NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.35, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.75, alpha: 1),
    ])?.draw(in: squircle, angle: 90)

    // Ombre douce interne basse pour le relief.
    NSGradient(colors: [
        NSColor.black.withAlphaComponent(0.18),
        NSColor.clear,
    ])?.draw(in: squircle, angle: 90)

    func drawSymbol(_ name: String, pointSize: CGFloat, color: NSColor, center: NSPoint) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = base.withSymbolConfiguration(config) else { return }
        // Rendu à la taille demandée en conservant le ratio du symbole.
        let ratio = symbol.size.height / symbol.size.width
        let width = pointSize
        let height = width * ratio
        let target = NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        symbol.draw(in: target)
    }

    // Nuage blanc, légèrement au-dessus du centre.
    drawSymbol("cloud.fill", pointSize: size * 0.58, color: .white,
               center: NSPoint(x: size / 2, y: size * 0.56))
    // Éclair jaune qui déborde du nuage vers le bas.
    drawSymbol("bolt.fill", pointSize: size * 0.30, color: NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.10, alpha: 1),
               center: NSPoint(x: size / 2, y: size * 0.40))

    return image
}

func savePNG(_ image: NSImage, pixels: Int, name: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { fatalError("rendu impossible") }
    rep.size = image.size
    // Re-rendu à la taille exacte en pixels.
    let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = scaled.representation(using: .png, properties: [:]) else { fatalError("png impossible") }
    try! png.write(to: iconset.appendingPathComponent(name))
}

let master = drawIcon(size: 1024)
let entries: [(Int, Int, String)] = [  // (points, scale, filename)
    (16, 1, "icon_16.png"), (16, 2, "icon_16@2x.png"),
    (32, 1, "icon_32.png"), (32, 2, "icon_32@2x.png"),
    (128, 1, "icon_128.png"), (128, 2, "icon_128@2x.png"),
    (256, 1, "icon_256.png"), (256, 2, "icon_256@2x.png"),
    (512, 1, "icon_512.png"), (512, 2, "icon_512@2x.png"),
]
for (points, scale, name) in entries {
    savePNG(master, pixels: points * scale, name: name)
}

let json = """
{
  "images" : [
""" + entries.map { points, scale, name in
    """
        { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(points)x\(points)" }
    """
}.joined(separator: ",\n") + """

  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! json.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("AppIcon générée dans \(iconset.path)")
