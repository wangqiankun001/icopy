import AppKit

// Draws the icopy app icon and produces Resources/AppIcon.icns.
let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let full = NSRect(x: 0, y: 0, width: s, height: s)
    NSColor.clear.setFill()
    full.fill()

    let bgRect = full.insetBy(dx: s * 0.035, dy: s * 0.035)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.225, yRadius: s * 0.225)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.30, green: 0.56, blue: 1.0, alpha: 1),
        ending: NSColor(calibratedRed: 0.12, green: 0.30, blue: 0.94, alpha: 1)
    )
    gradient?.draw(in: bgPath, angle: -75)

    // Clipboard board.
    let board = NSRect(x: s * 0.275, y: s * 0.175, width: s * 0.45, height: s * 0.60)
    let boardPath = NSBezierPath(roundedRect: board, xRadius: s * 0.065, yRadius: s * 0.065)
    NSColor.white.withAlphaComponent(0.97).setFill()
    boardPath.fill()

    // Clip at the top.
    let clip = NSRect(x: s * 0.415, y: s * 0.705, width: s * 0.17, height: s * 0.095)
    let clipPath = NSBezierPath(roundedRect: clip, xRadius: s * 0.032, yRadius: s * 0.032)
    NSColor(calibratedRed: 0.16, green: 0.37, blue: 0.98, alpha: 1).setFill()
    clipPath.fill()

    // Text lines.
    let lineColor = NSColor(calibratedRed: 0.29, green: 0.52, blue: 1.0, alpha: 0.95)
    let lines: [(CGFloat, CGFloat)] = [
        (0.53, 0.275),
        (0.42, 0.275),
        (0.31, 0.165)
    ]
    for (y, width) in lines {
        let line = NSRect(x: s * 0.365, y: s * y, width: s * width, height: s * 0.052)
        let linePath = NSBezierPath(roundedRect: line, xRadius: s * 0.026, yRadius: s * 0.026)
        lineColor.setFill()
        linePath.fill()
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        return nil
    }
    return png
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in variants {
    guard let data = draw(size: size) else {
        fatalError("Failed to draw icon \(name)")
    }
    try data.write(to: iconset.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    fatalError("iconutil failed")
}
try? FileManager.default.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns")
