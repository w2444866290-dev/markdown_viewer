import CryptoKit
import Foundation
import Testing

@Suite
struct DebugFixtureTests {
    private static let expectedByteCount = 3_470
    private static let expectedLineCount = 113
    private static let expectedSHA256 = "cbcdfe19a3383f175f1e9beb78afce473f335fd0e8e814bc799f3a1deade0d9f"

    @Test
    func authoritativeFixtureHasStableByteContract() throws {
        let fixtureData = try Data(contentsOf: repositoryURL("ui/格式示例.md"))
        let fixture = try #require(String(data: fixtureData, encoding: .utf8))

        #expect(fixtureData.count == Self.expectedByteCount)
        #expect(fixture.split(separator: "\n", omittingEmptySubsequences: false).count == Self.expectedLineCount)
        #expect(sha256(fixtureData) == Self.expectedSHA256)
        #expect(fixtureData.last != 0x0A)
    }

    @Test
    func authoritativeFixtureMatchesPrototypeSeedByteForByte() throws {
        let fixtureData = try Data(contentsOf: repositoryURL("ui/格式示例.md"))
        let html = try String(
            contentsOf: repositoryURL("ui/Markdown Viewer.dc.html"),
            encoding: .utf8
        )
        let prototypeSeed = try extractPrototypeSeed(from: html)
        let prototypeData = try #require(prototypeSeed.data(using: .utf8))

        // HTML is checked only for prototype drift; the Markdown file remains the build input.
        #expect(fixtureData == prototypeData)
    }

    private func repositoryURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func extractPrototypeSeed(from html: String) throws -> String {
        let startMarker = "'格式示例.md': ["
        let endMarker = "].join('\\n'),"
        let start = try #require(html.range(of: startMarker))
        let tail = html[start.upperBound...]
        let end = try #require(tail.range(of: endMarker))

        return try tail[..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                var literal = line.trimmingCharacters(in: .whitespaces)
                guard !literal.isEmpty else { return nil }
                if literal.hasSuffix(",") {
                    literal.removeLast()
                }
                guard literal.first == "'", literal.last == "'" else {
                    throw FixtureError.invalidLiteral(literal)
                }
                return try decodeJavaScriptString(literal.dropFirst().dropLast())
            }
            .joined(separator: "\n")
    }

    private func decodeJavaScriptString(_ source: Substring) throws -> String {
        var output = ""
        var iterator = source.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                output.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                throw FixtureError.danglingEscape
            }
            switch escaped {
            case "\\", "'", "\"": output.append(escaped)
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            default: throw FixtureError.unsupportedEscape(escaped)
            }
        }
        return output
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
