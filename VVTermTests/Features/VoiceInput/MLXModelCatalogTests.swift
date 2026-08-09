import XCTest
@testable import VVTerm

final class MLXModelCatalogTests: XCTestCase {
    func testOptionLookupTrimsWhitespace() {
        let option = MLXModelCatalog.option(
            for: "  mlx-community/whisper-tiny-mlx \n",
            kind: .whisper
        )

        XCTAssertEqual(option?.id, "mlx-community/whisper-tiny-mlx")
        XCTAssertEqual(option?.kind, .whisper)
    }

    func testOptionLookupRespectsModelKind() {
        XCTAssertNil(
            MLXModelCatalog.option(
                for: "mlx-community/parakeet-tdt-0.6b-v2",
                kind: .whisper
            )
        )
    }

    func testAllOptionsIncludesWhisperAndParakeetPresets() {
        XCTAssertEqual(MLXModelCatalog.allOptions.count, 8)
        XCTAssertTrue(MLXModelCatalog.allOptions.contains { $0.kind == .whisper })
        XCTAssertTrue(MLXModelCatalog.allOptions.contains { $0.kind == .parakeetTDT })
    }

    func testEveryVisibleOptionDerivesItsSizeFromTheManifest() throws {
        for kind in MLXModelKind.allCases {
            for option in MLXModelCatalog.options(for: kind) {
                let manifest = try XCTUnwrap(
                    MLXModelCatalog.downloadManifest(for: option.id, kind: kind)
                )
                XCTAssertEqual(option.expectedDownloadBytes, manifest.expectedBytes)
                XCTAssertEqual(
                    option.downloadSizeLabel,
                    ByteCountFormatter.string(
                        fromByteCount: try XCTUnwrap(manifest.expectedBytes),
                        countStyle: .file
                    )
                )
            }
        }
    }

}
