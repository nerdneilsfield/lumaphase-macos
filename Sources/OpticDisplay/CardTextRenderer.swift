import AppKit
import Metal
import OpticCore

public struct CardText {
    public let texture: MTLTexture
    public let pixelSize: PixelSize
}

/// CoreText/AppKit text rasterised once per card into an opaque black texture.
/// The card band is black, so an opaque quad blends in without any colour maths.
public enum CardTextRenderer {
    public static func make(
        device: MTLDevice,
        lines: [String],
        pixelSize: PixelSize
    ) -> CardText? {
        guard pixelSize.width > 8, pixelSize.height > 8, !lines.isEmpty else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize.width,
            pixelsHigh: pixelSize.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixelSize.width * 4,
            bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let lineHeight = CGFloat(pixelSize.height) / CGFloat(lines.count)
        let fontSize = max(10, lineHeight * 0.62)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        for (index, line) in lines.enumerated() {
            let y = CGFloat(pixelSize.height) - CGFloat(index + 1) * lineHeight + (lineHeight - fontSize) / 2
            let rect = NSRect(x: 8, y: y, width: CGFloat(pixelSize.width) - 16, height: lineHeight)
            (line as NSString).draw(in: rect, withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let data = rep.bitmapData
        else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, pixelSize.width, pixelSize.height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: rep.bytesPerRow
        )
        return CardText(texture: texture, pixelSize: pixelSize)
    }
}
