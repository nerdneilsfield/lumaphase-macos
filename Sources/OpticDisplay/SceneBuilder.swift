import Foundation
import OpticCore

public struct RGBA8: Equatable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(code: UInt8) {
        self.init(code, code, code, 255)
    }

    public static let black = RGBA8(0, 0, 0)
    public static let white = RGBA8(255, 255, 255)
    public static let midGray = RGBA8(128, 128, 128)
}

/// One vertex of the SDR scene. Byte layout is shared with the Metal shader:
/// position (8), uv (8), packed RGBA (4), 4 bytes padding → stride 24.
public struct SceneVertex: Equatable {
    public var position: SIMD2<Float>
    public var uv: SIMD2<Float>
    public var color: UInt32
    public var padding: UInt32 = 0

    public init(position: SIMD2<Float>, uv: SIMD2<Float> = SIMD2(0.5, 0.5), color: UInt32) {
        self.position = position
        self.uv = uv
        self.color = color
    }

    public static func pack(_ color: RGBA8) -> UInt32 {
        UInt32(color.r) | (UInt32(color.g) << 8) | (UInt32(color.b) << 16) | (UInt32(color.a) << 24)
    }
}

public struct Scene {
    /// Solid geometry drawn with a 1x1 white texture.
    public var solid: [SceneVertex] = []
    /// Textured quad(s) drawn with the card text texture.
    public var text: [SceneVertex] = []
    public init(solid: [SceneVertex] = [], text: [SceneVertex] = []) {
        self.solid = solid
        self.text = text
    }
}

public enum CalibrationScreen: Equatable {
    case geometry(moduleCount: Int)
    case staircase(levels: [UInt8])
    case complementary(flip: Bool)
}

/// Pure, testable scene construction in integer drawable pixels. The Metal
/// renderer only uploads these vertices; no geometry decisions happen on the GPU.
public enum SceneBuilder {
    // MARK: - Primitives

    public static func quad(
        _ p0: PixelPoint, _ p1: PixelPoint, _ p2: PixelPoint, _ p3: PixelPoint,
        color: RGBA8
    ) -> [SceneVertex] {
        let packed = SceneVertex.pack(color)
        func vertex(_ point: PixelPoint) -> SceneVertex {
            SceneVertex(position: SIMD2(Float(point.x), Float(point.y)), color: packed)
        }
        return [vertex(p0), vertex(p1), vertex(p2), vertex(p0), vertex(p2), vertex(p3)]
    }

    public static func rect(_ rect: RectPx, color: RGBA8) -> [SceneVertex] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        return quad(
            PixelPoint(x: rect.x0, y: rect.y0),
            PixelPoint(x: rect.x1, y: rect.y0),
            PixelPoint(x: rect.x1, y: rect.y1),
            PixelPoint(x: rect.x0, y: rect.y1),
            color: color
        )
    }

    public static func background(_ size: PixelSize, color: RGBA8 = .black) -> [SceneVertex] {
        rect(RectPx(x0: 0, y0: 0, x1: size.width, y1: size.height), color: color)
    }

    public static func boundingBox(_ points: [PixelPoint]) -> RectPx {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return RectPx(x0: xs.min() ?? 0, y0: ys.min() ?? 0, x1: xs.max() ?? 0, y1: ys.max() ?? 0)
    }

    // MARK: - ArUco markers

    /// White quiet zone, black border and 4x4 data cells for one marker.
    /// `cell` interpolation follows the marker's transformed corner order, so a
    /// 90/180/270 degree pattern rotates the data cells with the marker.
    public static func markerVertices(_ marker: MarkerPlacement) -> [SceneVertex] {
        guard let bits = ArucoMarkers.bits(for: marker.id) else { return [] }
        let corners = marker.cornersPx
        guard corners.count == 4 else { return [] }
        let cell = marker.cellSizePx
        let outer = ArucoMarkers.bitSize + 2 * ArucoMarkers.borderCells
        let box = boundingBox(corners)
        var vertices: [SceneVertex] = []
        // Quiet zone: at least one cell of white around the black border.
        vertices += rect(
            RectPx(x0: box.x0 - marker.quietZonePx, y0: box.y0 - marker.quietZonePx,
                   x1: box.x1 + marker.quietZonePx, y1: box.y1 + marker.quietZonePx),
            color: .white
        )

        let topLeft = corners[0]
        let topRight = corners[1]
        let bottomLeft = corners[3]
        let dx = (topRight.x - topLeft.x) / outer
        let dy = (topRight.y - topLeft.y) / outer
        let ex = (bottomLeft.x - topLeft.x) / outer
        let ey = (bottomLeft.y - topLeft.y) / outer
        _ = cell

        func point(_ column: Int, _ row: Int) -> PixelPoint {
            PixelPoint(
                x: topLeft.x + column * dx + row * ex,
                y: topLeft.y + column * dy + row * ey
            )
        }

        for row in 0..<outer {
            for column in 0..<outer {
                let isBorder = row == 0 || column == 0 || row == outer - 1 || column == outer - 1
                let color: RGBA8
                if isBorder {
                    color = .black
                } else {
                    let bit = ArucoMarkers.bit(bits, row: row - 1, column: column - 1)
                    color = bit == 1 ? .white : .black
                }
                vertices += quad(
                    point(column, row),
                    point(column + 1, row),
                    point(column + 1, row + 1),
                    point(column, row + 1),
                    color: color
                )
            }
        }
        return vertices
    }

    // MARK: - Frames

    public static func frameBackgroundAndMarkers(_ layout: LayoutSpec, fill: RGBA8 = .black) -> [SceneVertex] {
        var vertices = background(layout.drawableSize, color: fill)
        for marker in layout.markers {
            vertices += markerVertices(marker)
        }
        return vertices
    }

    public static func dynamicScene(_ layout: LayoutSpec, bits: PatternBits) -> Scene {
        var solid = frameBackgroundAndMarkers(layout)
        let codes = bits.codes(layout.levels)
        for (index, rect) in layout.modules.enumerated() where index < codes.count {
            solid += self.rect(rect, color: RGBA8(code: codes[index]))
        }
        return Scene(solid: solid)
    }

    public static func calibrationScene(
        _ layout: LayoutSpec, _ screen: CalibrationScreen
    ) -> Scene {
        var solid = frameBackgroundAndMarkers(layout)
        let dynamic = layout.dynamicRectPx
        switch screen {
        case .geometry:
            // One-pixel boundaries: the same integers exported in layout.json.
            for rect in layout.modules {
                if layout.patternRotationDeg % 180 == 0 {
                    solid += self.rect(RectPx(x0: rect.x0, y0: dynamic.y0, x1: rect.x0 + 1, y1: dynamic.y1),
                                       color: .white)
                } else {
                    solid += self.rect(RectPx(x0: dynamic.x0, y0: rect.y0, x1: dynamic.x1, y1: rect.y0 + 1),
                                       color: .white)
                }
            }
            solid += self.rect(RectPx(x0: dynamic.x0, y0: dynamic.y0, x1: dynamic.x1, y1: dynamic.y0 + 1), color: .white)
            solid += self.rect(RectPx(x0: dynamic.x0, y0: dynamic.y1 - 1, x1: dynamic.x1, y1: dynamic.y1), color: .white)
        case .staircase(let levels):
            let width = dynamic.width
            guard !levels.isEmpty, width > 0 else { break }
            for (index, level) in levels.enumerated() {
                let x0 = dynamic.x0 + index * width / levels.count
                let x1 = dynamic.x0 + (index + 1) * width / levels.count
                solid += self.rect(RectPx(x0: x0, y0: dynamic.y0, x1: x1, y1: dynamic.y1),
                                   color: RGBA8(code: level))
            }
        case .complementary(let flip):
            // Equal light/dark area: neighbouring modules always alternate.
            for (index, rect) in layout.modules.enumerated() {
                let isHigh = (index % 2 == 0) != flip
                let level = isHigh ? layout.levels.high : layout.levels.low
                solid += self.rect(rect, color: RGBA8(code: level))
            }
        }
        return Scene(solid: solid)
    }

    public static func cardScene(_ layout: LayoutSpec, dynamicFill: RGBA8 = .midGray) -> Scene {
        var solid = frameBackgroundAndMarkers(layout)
        solid += rect(layout.dynamicRectPx, color: dynamicFill)
        return Scene(solid: solid)
    }

    /// Card text band in *pattern* coordinates: between the top corner markers,
    /// above the dynamic area. Recomputes the pre-rotation dynamic rect from the
    /// contract percentages because `LayoutSpec` exports rotated rects only.
    public static func patternTextRect(_ layout: LayoutSpec) -> RectPx {
        let w = layout.patternSize.width
        let h = layout.patternSize.height
        let bw = w * LayoutBuilder.dynamicWidthPercent / 100
        let bh = h * LayoutBuilder.dynamicHeightPercent / 100
        let a = (w - bw) / 2
        let c = (h - bh) / 2
        let cell = max(2, layout.markers.first?.cellSizePx ?? 2)
        let markerSpan = 9 * cell
        let x0 = a + markerSpan
        let x1 = a + bw - markerSpan
        let y0 = cell
        let y1 = max(y0 + 24, c - cell)
        return RectPx(x0: x0, y0: y0, x1: max(x0 + 64, x1), y1: y1)
    }

    /// Text quad for a card. The texture is rendered horizontally in pattern
    /// space, so the UV assignment follows the same rotation as the pattern.
    public static func textQuad(patternRect: RectPx, patternSize: PixelSize, rotationDeg: Int) -> [SceneVertex] {
        let packed = SceneVertex.pack(.white)
        let local = patternRect.corners
        let uvs: [(Float, Float)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        let mapped = local.map { PatternRotation.map($0, degrees: rotationDeg, patternSize: patternSize) }
        func vertex(_ index: Int) -> SceneVertex {
            SceneVertex(
                position: SIMD2(Float(mapped[index].x), Float(mapped[index].y)),
                uv: SIMD2(uvs[index].0, uvs[index].1),
                color: packed
            )
        }
        return [vertex(0), vertex(1), vertex(2), vertex(0), vertex(2), vertex(3)]
    }
}
