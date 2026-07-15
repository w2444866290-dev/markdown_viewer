import Foundation

/// The single syntax authority for fenced Markdown blocks.
///
/// An opening fence is any run of at least three backticks or tildes after
/// indentation. A closing fence must use the same marker, contain at least as
/// many markers, and have only horizontal whitespace after the run.
enum MarkdownFenceSyntax {
    struct Fence: Equatable, Sendable {
        let marker: Character
        let count: Int
        let infoString: String

        var language: String {
            infoString.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first
                .map(String.init) ?? ""
        }
    }

    struct Content: Equatable, Sendable {
        let fence: Fence
        let language: String
        let code: String
        let isClosed: Bool
    }

    static func openingFence(in line: String) -> Fence? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }
        let count = trimmed.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        return Fence(marker: marker, count: count, infoString: info)
    }

    static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let count = trimmed.prefix(while: { $0 == fence.marker }).count
        guard count >= fence.count else { return false }
        return trimmed.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Splits a complete or unterminated fenced block for rendering and copying.
    /// Fence lines and the line terminator immediately before a closing fence are
    /// excluded from `code`; terminators between body lines remain byte-identical.
    static func content(in source: String) -> Content? {
        let lines = sourceLines(source)
        guard let first = lines.first,
              let fence = openingFence(in: first.content) else { return nil }
        let closingIndex = lines.indices.dropFirst().first(where: {
            isClosingFence(lines[$0].content, matching: fence)
        })
        let end = closingIndex ?? lines.endIndex
        var pieces: [String] = []
        if end > 1 {
            pieces.reserveCapacity((end - 1) * 2)
            for index in 1..<end {
                pieces.append(lines[index].content)
                if index + 1 < end || closingIndex == nil {
                    pieces.append(lines[index].terminator)
                }
            }
        }
        return Content(
            fence: fence,
            language: fence.language,
            code: pieces.joined(),
            isClosed: closingIndex != nil
        )
    }

    private struct SourceLine {
        let content: String
        let terminator: String
    }

    private static func sourceLines(_ source: String) -> [SourceLine] {
        let text = source as NSString
        guard text.length > 0 else { return [] }
        var result: [SourceLine] = []
        var start = 0
        var cursor = 0
        while cursor < text.length {
            let character = text.character(at: cursor)
            guard character == 0x0A || character == 0x0D else {
                cursor += 1
                continue
            }
            let content = text.substring(
                with: NSRange(location: start, length: cursor - start)
            )
            let terminator: String
            if character == 0x0D,
               cursor + 1 < text.length,
               text.character(at: cursor + 1) == 0x0A {
                terminator = "\r\n"
                cursor += 2
            } else {
                terminator = character == 0x0D ? "\r" : "\n"
                cursor += 1
            }
            result.append(SourceLine(content: content, terminator: terminator))
            start = cursor
        }
        if start < text.length {
            result.append(SourceLine(content: text.substring(from: start), terminator: ""))
        }
        return result
    }
}
