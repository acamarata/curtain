import XCTest
@testable import CurtainShared

final class HexColorTests: XCTestCase {
    func testRoundTripBlack() {
        let rgb = HexColor.toRGB("#000000")
        XCTAssertNotNil(rgb)
        XCTAssertEqual(HexColor.fromRGB(rgb!.r, rgb!.g, rgb!.b), "#000000")
    }

    func testRoundTripWhite() {
        let rgb = HexColor.toRGB("#ffffff")
        XCTAssertNotNil(rgb)
        XCTAssertEqual(rgb!.r, 1.0, accuracy: 1e-9)
        XCTAssertEqual(HexColor.fromRGB(rgb!.r, rgb!.g, rgb!.b), "#ffffff")
    }

    func testRoundTripArbitrary() {
        let rgb = HexColor.toRGB("#1a2b3c")
        XCTAssertNotNil(rgb)
        XCTAssertEqual(HexColor.fromRGB(rgb!.r, rgb!.g, rgb!.b), "#1a2b3c")
    }

    func testToRGBWithoutHashPrefix() {
        XCTAssertNotNil(HexColor.toRGB("1a2b3c"))
    }

    func testRejectsMalformed() {
        XCTAssertNil(HexColor.toRGB("#12345"))    // too short
        XCTAssertNil(HexColor.toRGB("#1234567"))  // too long
        XCTAssertNil(HexColor.toRGB("#gggggg"))   // non-hex
        XCTAssertNil(HexColor.toRGB(""))          // empty
    }

    func testFromRGBClamps() {
        XCTAssertEqual(HexColor.fromRGB(2.0, -1.0, 0.5), "#ff0080")
    }

    func testFromRGBKnownValue() {
        // 26/255, 43/255, 60/255 == 0x1a, 0x2b, 0x3c
        XCTAssertEqual(HexColor.fromRGB(26.0 / 255, 43.0 / 255, 60.0 / 255), "#1a2b3c")
    }
}
