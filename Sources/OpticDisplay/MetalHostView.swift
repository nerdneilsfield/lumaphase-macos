import AppKit
import Metal
import OpticCore

/// An `NSView` backed directly by a `CAMetalLayer`, sized in drawable pixels.
public final class MetalHostView: NSView {
    public let metalLayer = CAMetalLayer()
    public var onDrawableSizeChange: ((PixelSize) -> Void)?

    public init(device: MTLDevice, colorSpace: CGColorSpace?) {
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = false
        metalLayer.wantsExtendedDynamicRangeContent = false
        metalLayer.colorspace = colorSpace
        layer = metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    public override var isOpaque: Bool { true }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    public var currentDrawableSize: PixelSize {
        PixelSize(width: Int(metalLayer.drawableSize.width), height: Int(metalLayer.drawableSize.height))
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        let size = CGSize(width: width, height: height)
        guard metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        metalLayer.contentsScale = scale
        onDrawableSizeChange?(PixelSize(width: width, height: height))
    }
}
