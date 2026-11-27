import XCTest
@testable import HostKit
#if canImport(CoreImage)
import CoreImage
#endif

final class QRCodeTests: XCTestCase {
    func testSizesGrowWithTheText() {
        XCTAssertEqual(QRCode("hi")?.size, 21)
        XCTAssertEqual(QRCode(String(repeating: "a", count: 300))?.size, 4 * 11 + 17)
        XCTAssertNil(QRCode(String(repeating: "a", count: 2000)))
    }

    #if canImport(CoreImage)
    /// Apple's own reader has to get back what went in, at every size.
    func testAppleReadsThemBack() throws {
        let link = "bench://pair?host=4f1d2c3b-a353-4000-8874-a4960e8970d2.local-only.workbench&token=abcDEF0123456789abcDEF0123456789&relay=wss://relay.example.com&room=2888d934df637251e6223cc6966a07fc60dd5c0586b4bb507bb537a3f3e3df73"
        var texts = [link, "hi", "bench://pair?host=box.tail1234.ts.net&token=abcDEF0123456789"]
        for length in stride(from: 10, through: 850, by: 40) {
            texts.append(String((0..<length).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789:/?&=".randomElement()! }))
        }
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for text in texts {
            let code = try XCTUnwrap(QRCode(text), "\(text.count) characters should fit")
            let scale = 6, margin = 4
            let side = (code.size + margin * 2) * scale
            var pixels = [UInt8](repeating: 255, count: side * side)
            for y in 0..<code.size {
                for x in 0..<code.size where code.modules[y][x] {
                    for dy in 0..<scale {
                        for dx in 0..<scale { pixels[((y + margin) * scale + dy) * side + (x + margin) * scale + dx] = 0 }
                    }
                }
            }
            let image = CIImage(bitmapData: Data(pixels), bytesPerRow: side, size: CGSize(width: side, height: side),
                                format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            let found = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertEqual(found, [text], "a code of \(text.count) characters (size \(code.size))")
        }
    }
    #endif
}
