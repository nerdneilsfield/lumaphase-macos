import Foundation

/// ArUco `DICT_4X4_50` markers 0–3.
///
/// Bytes are copied from `third_party/opencv-4.10.0/aruco-4x4-50-first4.json`,
/// which records the OpenCV 4.10.0 source:
/// `modules/objdetect/src/aruco/predefined_dictionaries.hpp` (first four entries
/// of `DICT_4X4_1000_BYTES`; `DICT_4X4_50` uses the first 50 entries).
///
/// Storage contract: two bytes per marker, row-major 4x4, each byte
/// most-significant bit first, 1 = white, 0 = black. Border and quiet zone are
/// not part of the bytes.
public enum ArucoMarkers {
    public static let dictionary = "DICT_4X4_50"
    public static let bitSize = 4
    public static let borderCells = 1

    /// id → the two official bytes, rotation 0.
    public static let rawBytes: [Int: [UInt8]] = [
        0: [181, 50],
        1: [15, 154],
        2: [51, 45],
        3: [153, 70]
    ]

    /// 16 row-major bits for one marker id, or nil when the id is not 0–3.
    public static func bits(for id: Int) -> [UInt8]? {
        guard let bytes = rawBytes[id], bytes.count == 2 else { return nil }
        var bits: [UInt8] = []
        bits.reserveCapacity(16)
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> UInt8(shift)) & 1)
            }
        }
        return bits
    }

    /// Bit at (row, column) of the 4x4 data area.
    public static func bit(_ bits: [UInt8], row: Int, column: Int) -> UInt8 {
        bits[row * bitSize + column]
    }
}
