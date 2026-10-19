package import CoreGraphics
import Foundation

/// Chronos's mark: a wristwatch at ten past ten. One drawing for both the app icon and the menu bar icon, so the two
/// can't drift apart.
package enum Logo {
    /// The watch, filling `rect` in `color` on a transparent background. Drawn in a 100 × 100 box with y pointing
    /// down, like an SVG.
    package static func drawWatch(in context: CGContext, rect: CGRect, color: CGColor) {
        context.saveGState()
        defer { context.restoreGState() }
        let scale = min(rect.width, rect.height) / 100
        context.translateBy(x: rect.midX - 50 * scale, y: rect.midY + 50 * scale)
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(color)
        context.setStrokeColor(color)

        // Straps, narrowing away from the case. They stop inside the case's rim, so the face stays clear.
        for (rim, end) in [(28.0, 8.0), (72.0, 92.0)] {
            context.move(to: CGPoint(x: 38, y: rim))
            context.addLine(to: CGPoint(x: 62, y: rim))
            context.addLine(to: CGPoint(x: 59.5, y: end))
            context.addLine(to: CGPoint(x: 40.5, y: end))
            context.closePath()
        }
        context.fillPath()

        // Case and crown.
        context.setLineWidth(7)
        context.strokeEllipse(in: CGRect(x: 26, y: 26, width: 48, height: 48))
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 75, y: 45, width: 6.5, height: 10),
                cornerWidth: 1.5,
                cornerHeight: 1.5,
                transform: nil
            )
        )
        context.fillPath()

        // Hands at ten past ten, and the pivot.
        context.setLineCap(.round)
        hand(context, degrees: -55, length: 10.5, width: 5)
        hand(context, degrees: 60, length: 15.5, width: 4)
        context.fillEllipse(in: CGRect(x: 46.5, y: 46.5, width: 7, height: 7))
    }

    /// The app icon: the watch in white on a black rounded square, on Apple's icon grid, where the square is 824 of
    /// 1024 points, centered.
    package static func drawAppIcon(in context: CGContext, size: CGFloat) {
        let inset = size * 100 / 1024
        let square = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let radius = square.width * 185.4 / 824
        context.addPath(CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        drawWatch(
            in: context,
            rect: square.insetBy(dx: square.width * 0.07, dy: square.width * 0.07),
            color: CGColor(gray: 1, alpha: 1)
        )
    }

    /// A hand from the center, at `degrees` clockwise from 12.
    private static func hand(_ context: CGContext, degrees: Double, length: Double, width: Double) {
        let angle = degrees * .pi / 180
        context.setLineWidth(width)
        context.move(to: CGPoint(x: 50, y: 50))
        context.addLine(to: CGPoint(x: 50 + length * sin(angle), y: 50 - length * cos(angle)))
        context.strokePath()
    }
}
