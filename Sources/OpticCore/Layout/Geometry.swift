import Foundation

/// Output pixel size. Coordinates are drawable pixels, not points.
public struct PixelSize: Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Integer output pixel coordinate.
public struct PixelPoint: Hashable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// Half-open rectangle `[x0,x1) x [y0,y1)` in output pixels.
public struct RectPx: Hashable {
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public var width: Int { x1 - x0 }
    public var height: Int { y1 - y0 }

    public var corners: [PixelPoint] {
        [
            PixelPoint(x: x0, y: y0),
            PixelPoint(x: x1, y: y0),
            PixelPoint(x: x1, y: y1),
            PixelPoint(x: x0, y: y1)
        ]
    }

    public func intersects(_ other: RectPx) -> Bool {
        x0 < other.x1 && other.x0 < x1 && y0 < other.y1 && other.y0 < y1
    }

    public func contains(_ other: RectPx) -> Bool {
        other.x0 >= x0 && other.y0 >= y0 && other.x1 <= x1 && other.y1 <= y1
    }

    public var jsonArray: [JSONValue] {
        [.int(Int64(x0)), .int(Int64(y0)), .int(Int64(x1)), .int(Int64(y1))]
    }
}

/// Pattern rotation: clockwise mapping of the logical pattern into output
/// coordinates. `patternSize` is the pre-rotation canvas size.
public enum PatternRotation {
    public static func isSupported(_ degrees: Int) -> Bool {
        degrees == 0 || degrees == 90 || degrees == 180 || degrees == 270
    }

    public static func map(_ point: PixelPoint, degrees: Int, patternSize: PixelSize) -> PixelPoint {
        switch degrees {
        case 0:
            return point
        case 90:
            return PixelPoint(x: patternSize.height - point.y, y: point.x)
        case 180:
            return PixelPoint(x: patternSize.width - point.x, y: patternSize.height - point.y)
        default: // 270
            return PixelPoint(x: point.y, y: patternSize.width - point.x)
        }
    }

    public static func rect(_ rect: RectPx, degrees: Int, patternSize: PixelSize) -> RectPx {
        let mapped = rect.corners.map { map($0, degrees: degrees, patternSize: patternSize) }
        let xs = mapped.map(\.x)
        let ys = mapped.map(\.y)
        return RectPx(x0: xs.min()!, y0: ys.min()!, x1: xs.max()!, y1: ys.max()!)
    }

    /// 3x3 homogeneous matrix, row-major. It explains the direction of the
    /// exported coordinates; readers must use the already rotated rects.
    public static func matrix(degrees: Int, patternSize: PixelSize) -> [[Double]] {
        switch degrees {
        case 0:
            return [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        case 90:
            return [[0, -1, Double(patternSize.height)], [1, 0, 0], [0, 0, 1]]
        case 180:
            return [[-1, 0, Double(patternSize.width)], [0, -1, Double(patternSize.height)], [0, 0, 1]]
        default: // 270
            return [[0, 1, 0], [-1, 0, Double(patternSize.width)], [0, 0, 1]]
        }
    }
}
