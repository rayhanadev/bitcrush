import AppKit

// Render a 1024×1024 app icon: a rounded "squircle" with an indigo→purple
// gradient and a centered ♪. Usage: swift make-icon.swift <out.png>
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024

guard
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else {
  FileHandle.standardError.write(Data("could not create bitmap\n".utf8))
  exit(1)
}
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = CGFloat(size)
let inset: CGFloat = 96  // transparent margin around the squircle
let rect = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let radius = rect.width * 0.2237
let panel = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let gradient = NSGradient(
  starting: NSColor(srgbRed: 0.40, green: 0.36, blue: 0.95, alpha: 1),
  ending: NSColor(srgbRed: 0.72, green: 0.33, blue: 0.95, alpha: 1))!
gradient.draw(in: panel, angle: -90)

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let glyph = NSAttributedString(
  string: "♪",
  attributes: [
    .font: NSFont.systemFont(ofSize: 560, weight: .semibold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph,
  ])
let glyphSize = glyph.size()
glyph.draw(
  in: NSRect(
    x: (canvas - glyphSize.width) / 2,
    y: (canvas - glyphSize.height) / 2 - 24,
    width: glyphSize.width, height: glyphSize.height))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write(Data("png encode failed\n".utf8))
  exit(1)
}
do {
  try png.write(to: URL(fileURLWithPath: outPath))
  print("wrote \(outPath)")
} catch {
  FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
  exit(1)
}
