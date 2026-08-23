import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// A decoded FITS image with pixel values normalized to [0, 1] — a single
/// plane for 2-D files, or one plane per channel for 3-axis color cubes
/// (NAXIS3 = channels, e.g. RGB stacks from smart telescopes).
public struct FITSImage {
    public let header: FITSHeader
    public let width: Int
    public let height: Int
    /// One row-major `width * height` plane per channel (1 = mono, 3 = RGB).
    public var planes: [[Float]]

    public var channelCount: Int { planes.count }

    /// Luminance view: the plane itself for mono images, the channel mean
    /// for color cubes.
    public var pixels: [Float] {
        guard planes.count > 1 else { return planes[0] }
        var luminance = [Float](repeating: 0, count: width * height)
        let weight = 1 / Float(planes.count)
        for plane in planes {
            for k in 0 ..< luminance.count {
                luminance[k] += plane[k] * weight
            }
        }
        return luminance
    }

    public init(header: FITSHeader, width: Int, height: Int, planes: [[Float]]) {
        precondition(!planes.isEmpty)
        self.header = header
        self.width = width
        self.height = height
        self.planes = planes
    }

    public init(header: FITSHeader, width: Int, height: Int, pixels: [Float]) {
        self.init(header: header, width: width, height: height, planes: [pixels])
    }

    public subscript(x: Int, y: Int) -> Float {
        get { planes[0][y * width + x] }
        set { planes[0][y * width + x] = newValue }
    }
}

/// Decodes FITS primary image data units. FITS stores all numeric data
/// big-endian; 16-bit integer data is byte-swapped (via vDSP where available)
/// before conversion to normalized 32-bit floats.
public enum FITSReader {
    public static func read(contentsOf url: URL) throws -> FITSImage {
        try read(data: Data(contentsOf: url))
    }

    public static func read(data: Data) throws -> FITSImage {
        let header = try FITSHeader(data: data)
        let naxis = try header.requiredInteger("NAXIS")
        if naxis == 0 {
            // Tile-compressed files (fpack) have an empty primary HDU and
            // carry the image in a BINTABLE extension.
            return try FITSTileDecompressor.read(data: data, primaryHeader: header)
        }
        guard naxis == 2 || naxis == 3 else { throw FITSError.unsupportedAxisCount(naxis) }
        let width = try header.requiredInteger("NAXIS1")
        let height = try header.requiredInteger("NAXIS2")
        let channels = naxis == 3 ? try header.requiredInteger("NAXIS3") : 1
        guard (1 ... 4).contains(channels) else { throw FITSError.unsupportedAxisCount(naxis) }
        let bitpix = header.bitpix
        let count = width * height * channels
        let bytesPerPixel = abs(bitpix) / 8
        let expected = count * bytesPerPixel
        let available = data.count - header.byteCount
        guard available >= expected else {
            throw FITSError.truncatedData(expected: expected, actual: max(available, 0))
        }
        let payload = data.subdata(in: header.byteCount ..< header.byteCount + expected)

        let physical: [Double]
        switch bitpix {
        case 8:
            physical = payload.map { Double($0) }
        case 16:
            physical = decodeBigEndianInt16(payload, count: count).map(Double.init)
        case 32:
            physical = payload.withUnsafeBytes { raw in
                raw.bindMemory(to: Int32.self).map { Double(Int32(bigEndian: $0)) }
            }
        case -32:
            physical = payload.withUnsafeBytes { raw in
                raw.bindMemory(to: UInt32.self).map {
                    Double(Float(bitPattern: UInt32(bigEndian: $0)))
                }
            }
        case -64:
            physical = payload.withUnsafeBytes { raw in
                raw.bindMemory(to: UInt64.self).map {
                    Double(bitPattern: UInt64(bigEndian: $0))
                }
            }
        default:
            throw FITSError.unsupportedBitpix(bitpix)
        }

        let planes = try normalizedPlanes(
            physical: physical, bitpix: bitpix,
            bzero: header.bzero, bscale: header.bscale,
            width: width, height: height, channels: channels
        )
        return FITSImage(header: header, width: width, height: height, planes: planes)
    }

    /// Applies the linear physical-value transform, normalizes to [0, 1]
    /// over the full range of the storage type (or data min/max for floats),
    /// and splits the payload into channel planes (FITS cube order: axis 1
    /// fastest, so the payload is a sequence of row-major planes).
    static func normalizedPlanes(
        physical: [Double], bitpix: Int, bzero: Double, bscale: Double,
        width: Int, height: Int, channels: Int
    ) throws -> [[Float]] {
        let scaled = physical.map { bzero + bscale * $0 }

        let range: ClosedRange<Double>
        switch bitpix {
        case 8: range = normalizationRange(bzero: bzero, bscale: bscale, lo: 0, hi: 255)
        case 16: range = normalizationRange(bzero: bzero, bscale: bscale, lo: -32768, hi: 32767)
        case 32: range = normalizationRange(bzero: bzero, bscale: bscale,
                                            lo: Double(Int32.min), hi: Double(Int32.max))
        default:
            let lo = scaled.min() ?? 0
            let hi = scaled.max() ?? 1
            range = lo ... max(hi, lo + .ulpOfOne)
        }

        let span = range.upperBound - range.lowerBound
        let pixels = scaled.map { Float(($0 - range.lowerBound) / span) }

        let planeSize = width * height
        return (0 ..< channels).map {
            Array(pixels[$0 * planeSize ..< ($0 + 1) * planeSize])
        }
    }

    private static func normalizationRange(
        bzero: Double, bscale: Double, lo: Double, hi: Double
    ) -> ClosedRange<Double> {
        let a = bzero + bscale * lo
        let b = bzero + bscale * hi
        let lower = min(a, b)
        let upper = max(a, b)
        return lower ... max(upper, lower + .ulpOfOne)
    }

    /// Byte-swaps a big-endian Int16 buffer into host order before float
    /// conversion. The tight loop over `byteSwapped` auto-vectorizes; on
    /// little-endian hosts this is the required swap, on big-endian hosts
    /// `Int16(bigEndian:)` is a no-op.
    static func decodeBigEndianInt16(_ payload: Data, count: Int) -> [Int16] {
        var values = [Int16](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { dest in
            payload.copyBytes(to: dest, count: count * MemoryLayout<Int16>.size)
        }
        values.withUnsafeMutableBufferPointer { buffer in
            for i in 0 ..< count {
                buffer[i] = Int16(bigEndian: buffer[i])
            }
        }
        return values
    }
}
