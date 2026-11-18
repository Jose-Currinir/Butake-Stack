import XCTest
@testable import ButakeStack

/// Entornos' text mode: the `.env` text and the rows it stands for.
final class EnvTextTests: XCTestCase {
    typealias Row = EnvironmentsView.Row

    private func rows() -> [Row] {
        [Row(key: "APP_NAME", value: "Tienda de ejemplo", secret: false, original: "APP_NAME"),
         Row(key: "APP_KEY", value: "", secret: true, original: "APP_KEY"),
         Row(key: "API_TOKEN", value: "", secret: true, original: "API_TOKEN"),
         Row(key: "APP_URL", value: "http://tienda.test:{port:tienda}", secret: false, original: "APP_URL")]
    }

    func testPlainValuesSurviveTheRoundTrip() {
        let values = ["", "simple", "con espacios", " borde ", "a #b", "\"citado\"", "'x'", "barra\\final\\", "c:\\ruta \"x\" #y", "precio $5", "{port:tienda}"]
        let rows = values.enumerated().map { Row(key: "K\($0.offset)", value: $0.element, secret: false, original: "K\($0.offset)") }
        let merged = EnvText.merge(EnvText.render(rows, stored: []), into: rows, stored: [])
        XCTAssertEqual(merged, rows)
    }

    func testSecretsAreNeverRendered() {
        var rows = rows()
        rows[2].newSecret = "valor-inventado"
        let text = EnvText.render(rows, stored: ["APP_KEY"])
        XCTAssertEqual(text, "APP_NAME=Tienda de ejemplo\nAPP_KEY=\(EnvText.mask)\nAPI_TOKEN=\(EnvText.mask)\nAPP_URL=http://tienda.test:{port:tienda}\n")
        XCTAssertFalse(text.contains("valor-inventado"))
    }

    func testUntouchedTextChangesNothing() {
        let rows = rows(), stored: Set = ["APP_KEY"]
        XCTAssertEqual(EnvText.merge(EnvText.render(rows, stored: stored), into: rows, stored: stored), rows)
    }

    func testEditingReplacesRemovesAndAdds() {
        let rows = rows(), stored: Set = ["APP_KEY", "API_TOKEN"]
        let text = "# comentario\nAPP_NAME=Otra\nAPP_KEY=nueva-clave\nAPI_TOKEN=\(EnvText.mask)\nNUEVA=1\nmedia linea\n"
        let merged = EnvText.merge(text, into: rows, stored: stored)
        XCTAssertEqual(merged.map(\.key), ["APP_NAME", "APP_KEY", "API_TOKEN", "NUEVA"])
        XCTAssertEqual(merged[0].value, "Otra")
        XCTAssertEqual(merged[0].id, rows[0].id)
        XCTAssertEqual(merged[1].newSecret, "nueva-clave")
        XCTAssertTrue(merged[1].secret)
        XCTAssertNil(merged[2].newSecret)
        XCTAssertTrue(merged[3].fromText)
        XCTAssertFalse(merged[3].secret)
        // Merging the same text again is a fixed point: typing is never rewritten under the caret.
        XCTAssertEqual(EnvText.merge(text, into: merged, stored: stored), merged)
    }

    func testClearingAStoredSecretEmptiesItAndAnEmptyOneStaysUntouched() {
        let rows = rows()
        let merged = EnvText.merge("APP_KEY=\nAPI_TOKEN=\n", into: rows, stored: ["APP_KEY"])
        XCTAssertEqual(merged[0].newSecret, "")
        XCTAssertNil(merged[1].newSecret)
    }

    func testARenamedSecretNeverSavesTheMask() {
        let merged = EnvText.merge("APP_SECRET=\(EnvText.mask)\n", into: rows(), stored: ["APP_KEY"])
        XCTAssertEqual(merged.map(\.value), [""])
        XCTAssertTrue(merged[0].fromText)
    }
}
