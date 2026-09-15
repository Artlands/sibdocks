import AppKit
import Foundation

/// Builds a standard macOS .icns file directly from the same SF Symbol used
/// by the status item. Keeping the symbol name here makes the bundle icon and
/// menu-bar icon intentionally share one visual identity.
let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon.icns")
let iconSizes: [(tag: String, pixels: Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
    ("ic08", 256), ("ic09", 512), ("ic10", 1024)
]

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

func symbolPNG(pixels: Int) -> Data {
    let size = NSSize(width: pixels, height: pixels)
    let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.72,
                                                      weight: .regular,
                                                      scale: .large)
    let symbol = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: nil)!
        .withSymbolConfiguration(configuration)!
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                  pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = min(size.width / symbol.size.width, size.height / symbol.size.height)
    let drawSize = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    let rect = NSRect(x: (size.width - drawSize.width) / 2,
                      y: (size.height - drawSize.height) / 2,
                      width: drawSize.width, height: drawSize.height)
    symbol.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

var chunks = Data()
for icon in iconSizes {
    let png = symbolPNG(pixels: icon.pixels)
    chunks.append(icon.tag.data(using: .ascii)!)
    appendBigEndian(UInt32(8 + png.count), to: &chunks)
    chunks.append(png)
}

var icon = Data("icns".utf8)
appendBigEndian(UInt32(8 + chunks.count), to: &icon)
icon.append(chunks)

try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try icon.write(to: destination, options: .atomic)
