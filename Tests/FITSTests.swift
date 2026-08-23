import XCTest
@testable import FitsnFinishCore

final class FITSTests: XCTestCase {
    // MARK: Header parsing

    func testHeaderParsesRequiredKeywords() throws {
        let data = FITSWriter.data(pixels: [Float](repeating: 0.5, count: 16), width: 4, height: 4)
        let header = try FITSHeader(data: data)
        XCTAssertEqual(header.string("SIMPLE"), "T")
        XCTAssertEqual(header.bitpix, 16)
        XCTAssertEqual(header.integer("NAXIS"), 2)
        XCTAssertEqual(header.integer("NAXIS1"), 4)
        XCTAssertEqual(header.integer("NAXIS2"), 4)
        XCTAssertEqual(header.bzero, 32768)
        XCTAssertEqual(header.bscale, 1)
        XCTAssertEqual(header.byteCount, FITSHeader.blockSize)
    }

    func testHeaderStripsCommentsAndQuotes() throws {
        var cards = "SIMPLE  =                    T / conforms"
            .padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "BITPIX  =                   16".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS   =                    2".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS1  =                    1".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS2  =                    1".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "OBJECT  = 'M 31    '           / target".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        var data = Data(cards.utf8)
        data.append(Data(count: FITSHeader.blockSize - data.count % FITSHeader.blockSize))

        let header = try FITSHeader(data: data)
        XCTAssertEqual(header.string("OBJECT"), "M 31")
        XCTAssertEqual(header.integer("BITPIX"), 16)
    }

    func testRejectsNonFITSData(){
        XCTAssertThrowsError(try FITSHeader(data: Data(count: FITSHeader.blockSize * 2))) { error in
            // An all-zero block never contains an END card.
            XCTAssertEqual(error as? FITSError, .truncatedHeader)
        }
        var junk = "NOTFITS = 1".padding(toLength: 80, withPad: " ", startingAt: 0)
        junk += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        junk = junk.padding(toLength: FITSHeader.blockSize, withPad: " ", startingAt: 0)
        XCTAssertThrowsError(try FITSHeader(data: Data(junk.utf8))) { error in
            XCTAssertEqual(error as? FITSError, .notFITS)
        }
    }

    // MARK: Big-endian decoding

    func testBigEndianInt16Decoding() {
        // 0x0102 big-endian = 258; 0xFF00 big-endian = -256.
        let payload = Data([0x01, 0x02, 0xFF, 0x00])
        let values = FITSReader.decodeBigEndianInt16(payload, count: 2)
        XCTAssertEqual(values, [258, -256])
    }

    func testReaderNormalizesUnsigned16BitRange() throws {
        // Full-scale ramp: 0, mid, max should normalize to 0, ~0.5, 1.
        let data = FITSWriter.data(pixels: [0, 0.5, 1, 0.25], width: 2, height: 2)
        let image = try FITSReader.read(data: data)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.pixels[0], 0, accuracy: 1e-4)
        XCTAssertEqual(image.pixels[1], 0.5, accuracy: 1e-4)
        XCTAssertEqual(image.pixels[2], 1, accuracy: 1e-4)
        XCTAssertEqual(image.pixels[3], 0.25, accuracy: 1e-4)
    }

    func testRoundTripPreservesPixels() throws {
        var pixels = [Float](repeating: 0, count: 100)
        for k in 0 ..< pixels.count {
            pixels[k] = Float(k) / Float(pixels.count - 1)
        }
        let image = try FITSReader.read(data: FITSWriter.data(pixels: pixels, width: 10, height: 10))
        for k in 0 ..< pixels.count {
            XCTAssertEqual(image.pixels[k], pixels[k], accuracy: 1.0 / 65535)
        }
    }

    func testColorCubeRoundTrip() throws {
        // 3-plane (RGB) cube, as produced by smart-telescope stacks
        // (e.g. Seestar): NAXIS=3 with NAXIS3=3, plane-sequential data.
        let red: [Float] = [0.1, 0.2, 0.3, 0.4]
        let green: [Float] = [0.5, 0.5, 0.5, 0.5]
        let blue: [Float] = [0.9, 0.8, 0.7, 0.6]
        let data = FITSWriter.data(planes: [red, green, blue], width: 2, height: 2)

        let header = try FITSHeader(data: data)
        XCTAssertEqual(header.integer("NAXIS"), 3)
        XCTAssertEqual(header.integer("NAXIS3"), 3)

        let image = try FITSReader.read(data: data)
        XCTAssertEqual(image.channelCount, 3)
        for (decoded, expected) in zip(image.planes, [red, green, blue]) {
            for k in 0 ..< 4 {
                XCTAssertEqual(decoded[k], expected[k], accuracy: 1.0 / 65535)
            }
        }
        // Luminance is the channel mean.
        XCTAssertEqual(image.pixels[0], (0.1 + 0.5 + 0.9) / 3, accuracy: 1e-3)
    }

    func testCubeWithTooManyChannelsThrows() {
        var cards = "SIMPLE  =                    T".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "BITPIX  =                   16".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS   =                    3".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS1  =                    2".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS2  =                    2".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS3  =                    7".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        var data = Data(cards.utf8)
        data.append(Data(count: FITSHeader.blockSize * 2 - data.count % FITSHeader.blockSize))
        XCTAssertThrowsError(try FITSReader.read(data: data)) { error in
            XCTAssertEqual(error as? FITSError, .unsupportedAxisCount(3))
        }
    }

    func testTruncatedDataThrows() throws {
        var data = FITSWriter.data(pixels: [Float](repeating: 0.5, count: 100), width: 10, height: 10)
        data = data.prefix(FITSHeader.blockSize + 10) // header + 5 pixels
        XCTAssertThrowsError(try FITSReader.read(data: data)) { error in
            guard case .truncatedData? = error as? FITSError else {
                return XCTFail("Expected truncatedData, got \(error)")
            }
        }
    }

    // MARK: Tile-compressed FITS (fpack convention)

    private func fixture(_ name: String) throws -> FITSImage {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "fits", subdirectory: "Fixtures"
        ))
        return try FITSReader.read(contentsOf: url)
    }

    func testRiceCompressed16BitMatchesUncompressed() throws {
        let plain = try fixture("plain16")
        let rice = try fixture("rice16")
        XCTAssertEqual(rice.width, plain.width)
        XCTAssertEqual(rice.height, plain.height)
        XCTAssertEqual(rice.planes[0], plain.planes[0], "RICE decode must be lossless")
    }

    func testGzipCompressed16BitMatchesUncompressed() throws {
        let plain = try fixture("plain16")
        let gzip = try fixture("gzip16")
        XCTAssertEqual(gzip.planes[0], plain.planes[0], "GZIP_1 decode must be lossless")
    }

    func testGzip2Float32MatchesUncompressed() throws {
        let plain = try fixture("plainf32")
        let gzip2 = try fixture("gzip2f32")
        XCTAssertEqual(gzip2.planes[0], plain.planes[0],
                       "GZIP_2 float decode must be lossless after unshuffling")
    }

    func testGzipQuantizedFloat32WithinQuantizationError() throws {
        let plain = try fixture("plainf32")
        let gzip = try fixture("gzip1q32")
        for k in 0 ..< plain.planes[0].count {
            XCTAssertEqual(gzip.planes[0][k], plain.planes[0][k], accuracy: 2e-3)
        }
    }

    func testRiceQuantizedFloat32WithinQuantizationError() throws {
        let plain = try fixture("plainf32")
        let rice = try fixture("ricef32")
        XCTAssertEqual(rice.width, plain.width)
        for k in 0 ..< plain.planes[0].count {
            XCTAssertEqual(rice.planes[0][k], plain.planes[0][k], accuracy: 2e-3)
        }
    }

    func testRiceCompressedColorCubeMatchesUncompressed() throws {
        let plain = try fixture("plaincube16")
        let rice = try fixture("ricecube16")
        XCTAssertEqual(rice.channelCount, 3)
        for c in 0 ..< 3 {
            XCTAssertEqual(rice.planes[c], plain.planes[c])
        }
    }

    func testFloat32FITSDecoding() throws {
        // Hand-build a BITPIX=-32 file.
        var cards = "SIMPLE  =                    T".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "BITPIX  =                  -32".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS   =                    2".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS1  =                    2".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS2  =                    1".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        var data = Data(cards.utf8)
        data.append(Data(count: FITSHeader.blockSize - data.count % FITSHeader.blockSize))
        for value: Float in [0.25, 0.75] {
            withUnsafeBytes(of: value.bitPattern.bigEndian) { data.append(contentsOf: $0) }
        }
        data.append(Data(count: FITSHeader.blockSize - 8))

        let image = try FITSReader.read(data: data)
        // Floats normalize over data min/max: 0.25 → 0, 0.75 → 1.
        XCTAssertEqual(image.pixels[0], 0, accuracy: 1e-5)
        XCTAssertEqual(image.pixels[1], 1, accuracy: 1e-5)
    }
}
