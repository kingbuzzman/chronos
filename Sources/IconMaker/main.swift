import ChronosCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Writes the app icon as an iconset, which make turns into AppIcon.icns with iconutil. With a second argument, also
// writes the menu bar icon at 2x to that PNG, for checking it by eye.
//
// Usage: IconMaker ICONSET [MENU_BAR_PNG]

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: IconMaker ICONSET [MENU_BAR_PNG]\n".utf8))
    exit(2)
}
let iconset = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try writePNG(pixels: points * scale, to: iconset.appendingPathComponent(name)) { context, size in
            Logo.drawAppIcon(in: context, size: size)
        }
    }
}
if arguments.count >= 3 {
    try writePNG(pixels: 36, to: URL(fileURLWithPath: arguments[2])) { context, size in
        Logo.drawWatch(
            in: context,
            rect: CGRect(x: 0, y: 0, width: size, height: size),
            color: CGColor(gray: 0, alpha: 1)
        )
    }
}

struct ImageError: Error, CustomStringConvertible {
    let description: String
}

func writePNG(pixels: Int, to url: URL, draw: (CGContext, CGFloat) -> Void) throws {
    guard
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { throw ImageError(description: "can't draw a \(pixels)-pixel image") }
    draw(context, CGFloat(pixels))
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw ImageError(description: "can't write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageError(description: "can't write \(url.path)") }
}
