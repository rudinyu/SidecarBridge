import Foundation
import XCTest

final class HostInputSourceStatusTests: XCTestCase {
    func testRoundTripPreservesUnknownLanguageAndLocalizedSourceName() throws {
        let status = HostInputSourceStatus(
            id: "org.example.inputmethod.japanese",
            language: "ja",
            name: "日本語 - ローマ字入力"
        )

        let parsed = try XCTUnwrap(HostInputSourceStatus.parse(detail: status.detail))
        XCTAssertEqual(parsed, status)
    }

    func testEmptySourceNameFallsBackToInputSourceIdentifier() throws {
        let status = HostInputSourceStatus(id: "com.apple.keylayout.US", language: "en", name: "")

        XCTAssertEqual(status.name, "com.apple.keylayout.US")
        XCTAssertEqual(try XCTUnwrap(HostInputSourceStatus.parse(detail: status.detail)).name, status.id)
    }

    func testEmptySourceNameUsesBoundedFallbackForLongIdentifier() throws {
        let status = HostInputSourceStatus(
            id: String(repeating: "a", count: 300),
            language: "en",
            name: ""
        )

        XCTAssertEqual(status.name, "Input source")
        XCTAssertEqual(try XCTUnwrap(HostInputSourceStatus.parse(detail: status.detail)), status)
    }

    func testParseRejectsMalformedPrefixBase64AndJSON() {
        XCTAssertNil(HostInputSourceStatus.parse(detail: "unknown-prefix:AAAA"))
        XCTAssertNil(HostInputSourceStatus.parse(detail: HostInputSourceStatus.prefix + "not base64!"))
        XCTAssertNil(HostInputSourceStatus.parse(detail: encoded("{")))
    }

    func testParseRejectsUnknownSchemaVersionAndFutureFields() {
        XCTAssertNil(HostInputSourceStatus.parse(detail: encoded(
            #"{"version":2,"id":"x","language":"en","name":"English"}"#
        )))
        XCTAssertNil(HostInputSourceStatus.parse(detail: encoded(
            #"{"version":1,"id":"x","language":"en","name":"English","future":true}"#
        )))
    }

    func testParseRejectsOversizedFieldsAndEncodedPayloads() {
        let oversizedID = String(repeating: "a", count: 513)
        XCTAssertNil(HostInputSourceStatus.parse(detail: encoded(payload(id: oversizedID))))

        let oversizedLanguage = String(repeating: "a", count: 33)
        XCTAssertNil(HostInputSourceStatus.parse(detail: encoded(payload(language: oversizedLanguage))))

        let oversizedName = String(repeating: "a", count: 257)
        XCTAssertNil(HostInputSourceStatus.parse(detail: encoded(payload(name: oversizedName))))

        let oversizedUTF8Name = String(repeating: "語", count: 86)
        XCTAssertNil(HostInputSourceStatus.parse(detail: encoded(payload(name: oversizedUTF8Name))))

        let oversizedEncodedPayload = HostInputSourceStatus.prefix
            + String(repeating: "A", count: 6_829)
        XCTAssertNil(HostInputSourceStatus.parse(detail: oversizedEncodedPayload))
    }

    private func payload(
        id: String = "com.apple.keylayout.US",
        language: String = "en",
        name: String = "U.S."
    ) -> String {
        #"{"version":1,"id":"\#(id)","language":"\#(language)","name":"\#(name)"}"#
    }

    private func encoded(_ json: String) -> String {
        HostInputSourceStatus.prefix + Data(json.utf8).base64EncodedString()
    }
}
