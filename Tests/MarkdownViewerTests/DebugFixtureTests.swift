import CryptoKit
import Foundation
import Testing

@Suite
struct DebugFixtureTests {
    private static let expectedByteCount = 3_470
    private static let expectedLineCount = 113
    private static let expectedSHA256 = "cbcdfe19a3383f175f1e9beb78afce473f335fd0e8e814bc799f3a1deade0d9f"

    @Test
    func fixtureExactlyMatchesAuthoritativeHTMLSeed() throws {
        let fixtureData = try Data(contentsOf: repositoryURL("Fixtures/Debug/格式示例.md"))
        let html = try String(
            contentsOf: repositoryURL("ui/Markdown Viewer.dc.html"),
            encoding: .utf8
        )
        let extracted = try extractSeed(named: "格式示例.md", from: html)
        let extractedData = try #require(extracted.data(using: .utf8))

        #expect(fixtureData == extractedData)
        #expect(fixtureData.count == Self.expectedByteCount)
        #expect(extracted.split(separator: "\n", omittingEmptySubsequences: false).count == Self.expectedLineCount)
        #expect(sha256(fixtureData) == Self.expectedSHA256)
        #expect(fixtureData.last != 0x0A)
    }

    private func repositoryURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func extractSeed(named name: String, from html: String) throws -> String {
        let startMarker = "'\(name)': ["
        let endMarker = "].join('\\n'),"
        let start = try #require(html.range(of: startMarker))
        let tail = html[start.upperBound...]
        let end = try #require(tail.range(of: endMarker))
        let arrayBody = tail[..<end.lowerBound]

        let values = try arrayBody
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                var literal = line.trimmingCharacters(in: .whitespaces)
                guard !literal.isEmpty else { return nil }
                if literal.hasSuffix(",") {
                    literal.removeLast()
                }
                guard literal.count >= 2,
                      literal.first == "'",
                      literal.last == "'" else {
                    throw FixtureError.invalidLiteral(literal)
                }
                literal.removeFirst()
                literal.removeLast()
                return try decodeJavaScriptSingleQuotedString(literal)
            }
        return values.joined(separator: "\n")
    }

    private func decodeJavaScriptSingleQuotedString(_ source: String) throws -> String {
        let scalars = Array(source.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\" else {
                output.append(scalar)
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else {
                throw FixtureError.danglingEscape
            }
            let escaped = scalars[index]
            switch escaped {
            case "\\", "'", "\"":
                output.append(escaped)
            case "n":
                output.append("\n")
            case "r":
                output.append("\r")
            case "t":
                output.append("\t")
            default:
                throw FixtureError.unsupportedEscape(Character(String(escaped)))
            }
            index += 1
        }

        return String(output)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum FixtureError: Error {
        case invalidLiteral(String)
        case danglingEscape
        case unsupportedEscape(Character)
    }
}
