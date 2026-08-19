import AppKit

// Regenerates AppIcon.icns from the app's OWN glyph geometry.
//
// Generating rather than hand-drawing is the point: StowGlyph owns the token
// path, so the Dock/Finder icon and the menu bar mark come from one function
// and cannot drift apart. Compiled against the real Sources by make-icon.sh,
// the same pattern AuthBar uses.
//
// The menu bar uses the freestanding Aurora mark. The app icon reverses that
// same geometry into a dark mark on an Aurora rounded-square field so it has
// enough visual mass in Finder and System Settings.

// NSImage drawing needs an initialised NSApplication; without it the graphics
// context is nil and drawing crashes.
_ = NSApplication.shared

let output = CommandLine.arguments.count > 1
    ? URL(filePath: CommandLine.arguments[1])
    : URL(filePath: "AppIcon.iconset")
let icnsOutput = CommandLine.arguments.count > 2
    ? URL(filePath: CommandLine.arguments[2])
    : URL(filePath: "AppIcon.icns")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// iconutil requires exactly these names; a missing size silently degrades to a
// blurry upscale in whichever context wanted it.
let variants: [(points: Int, scale: Int, icnsType: String)] = [
    (16, 1, "ic04"), (16, 2, "ic11"),
    (32, 1, "ic05"), (32, 2, "ic12"),
    (128, 1, "ic07"), (128, 2, "ic13"),
    (256, 1, "ic08"), (256, 2, "ic14"),
    (512, 1, "ic09"), (512, 2, "ic10"),
]

var chunks: [(type: String, png: Data)] = []
for (points, scale, icnsType) in variants {
    let pixels = points * scale
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size, flipped: false) { canvas in
        let tile = canvas.insetBy(dx: canvas.width * 0.04, dy: canvas.height * 0.04)
        let background = NSBezierPath(
            roundedRect: tile,
            xRadius: canvas.width * 0.23,
            yRadius: canvas.height * 0.23
        )
        background.addClip()
        let paint = StowGlyph.paint(for: .tidy)
        let gradient = NSGradient(colors: paint.stops)
            ?? NSGradient(colors: [.systemGreen, .systemIndigo])!
        gradient.draw(in: tile, angle: 315)

        let markBox = canvas.insetBy(dx: canvas.width * 0.14, dy: canvas.height * 0.14)
        NSColor(srgbRed: 0.035, green: 0.043, blue: 0.059, alpha: 1).setFill()
        StowGlyph.tokenPath(in: markBox).fill()
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(pixels)px\n".utf8))
        exit(1)
    }
    let name = scale == 1 ? "icon_\(points)x\(points).png"
                          : "icon_\(points)x\(points)@2x.png"
    do {
        try png.write(to: output.appending(path: name))
        chunks.append((icnsType, png))
    } catch {
        FileHandle.standardError.write(Data("failed to write \(name): \(error)\n".utf8))
        exit(1)
    }
}

func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    let value = value.bigEndian
    return withUnsafeBytes(of: value) { Array($0) }
}

var icns = Data("icns".utf8)
let totalSize = 8 + chunks.reduce(0) { $0 + 8 + $1.png.count }
icns.append(contentsOf: bigEndianBytes(UInt32(totalSize)))
for chunk in chunks {
    icns.append(Data(chunk.type.utf8))
    icns.append(contentsOf: bigEndianBytes(UInt32(8 + chunk.png.count)))
    icns.append(chunk.png)
}

do {
    try icns.write(to: icnsOutput, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("failed to write \(icnsOutput.path): \(error)\n".utf8))
    exit(1)
}

print("wrote \(variants.count) variants to \(output.path)")
print("wrote \(icnsOutput.path) (\(icns.count) bytes)")
