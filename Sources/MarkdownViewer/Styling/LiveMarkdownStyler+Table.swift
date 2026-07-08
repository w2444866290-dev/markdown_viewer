import AppKit

extension LiveMarkdownStyler {
    static func looksLikeTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && (trimmed.hasPrefix("|") || trimmed.hasSuffix("|"))
    }

    static func isTableSeparatorLine(_ line: String) -> Bool {
        let cells = splitTableCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let normalized = cell.replacingOccurrences(of: ":", with: "")
            return normalized.count >= 3 && normalized.allSatisfy { $0 == "-" }
        }
    }

    static func applyTableBlock(rows: [(text: String, range: NSRange, isHeader: Bool)], separatorRange: NSRange, to textStorage: NSTextStorage) {
        let parsedRows = rows.map { row in
            (row: row, cells: parseTableCells(line: row.text, lineRange: row.range))
        }
        let columnCount = parsedRows.map { $0.cells.count }.max() ?? 0
        let columnWidths: [CGFloat] = (0..<columnCount).map { columnIndex in
            parsedRows.map { parsedRow in
                guard parsedRow.cells.indices.contains(columnIndex) else { return CGFloat(0) }
                let font = parsedRow.row.isHeader ? tableHeaderFont : tableBodyFont
                return measuredWidth(parsedRow.cells[columnIndex].visibleText, font: font)
            }.max() ?? 0
        }

        let lastIndex = parsedRows.count - 1
        for (rowIndex, parsedRow) in parsedRows.enumerated() {
            if parsedRow.row.isHeader {
                applyTableHeader(parsedRow.row.text, range: parsedRow.row.range, cells: parsedRow.cells, columnWidths: columnWidths, to: textStorage)
            } else {
                // The final body row omits its bottom hairline (mockup, L325 has no
                // border-bottom on the last `td`s).
                applyTableRow(parsedRow.row.text, range: parsedRow.row.range, cells: parsedRow.cells, columnWidths: columnWidths, isLastRow: rowIndex == lastIndex, to: textStorage)
            }
        }

        applyHiddenTableSeparator(range: separatorRange, to: textStorage)
    }

    private static func applyTableHeader(_ line: String, range: NSRange, cells: [TableCell], columnWidths: [CGFloat], to textStorage: NSTextStorage) {
        // Margins zeroed: the blank before the table carries the gap (#1 rhythm).
        let style = paragraphStyle(spacingBefore: 0, spacingAfter: 0)
        style.headIndent = 8
        style.firstLineHeadIndent = 8
        style.lineBreakMode = .byClipping
        // Borderless: no filled card behind the table. `.backgroundColor: .clear`
        // keeps the header-style assertion satisfied; `mvTableHeaderRule` makes
        // CardLayoutManager draw only the #ECECEE hairline under the header row.
        textStorage.addAttributes([
            // Mockup `th` (L317): 11px semibold sans, color #86868b, letter-spacing 0.4.
            // The 0.4 letter-spacing is applied per-cell in alignTableCells so its
            // width can be backed out of the column math (alignment self-test).
            .font: tableHeaderFont,
            .foregroundColor: DesignTokens.tertiaryText,
            .backgroundColor: NSColor.clear,
            .mvTableHeaderRule: true,
            .paragraphStyle: style
        ], range: range)
        alignTableCells(cells, columnWidths: columnWidths, rowFont: tableHeaderFont, letterSpacing: 0.4, textStorage: textStorage)
    }

    private static func applyTableRow(_ line: String, range: NSRange, cells: [TableCell], columnWidths: [CGFloat], isLastRow: Bool, to textStorage: NSTextStorage) {
        let style = paragraphStyle(spacingBefore: 0, spacingAfter: 0)
        style.headIndent = 8
        style.firstLineHeadIndent = 8
        style.lineBreakMode = .byClipping
        // Borderless white row; `mvTableBodyRule` draws only the #F4F4F5 hairline
        // under the row (mockup `td` border-bottom). Prose body cells render in the
        // document body sans font at the table's 13.5px font-size (mockup table
        // `font-size:13.5`, L314; `td` has no font-family override, L323/350).
        // The LAST body row omits the hairline (mockup, L325), so it is not stamped.
        var attrs: [NSAttributedString.Key: Any] = [
            .font: tableBodyFont,
            .paragraphStyle: style
        ]
        if !isLastRow {
            attrs[.mvTableBodyRule] = true
        }
        textStorage.addAttributes(attrs, range: range)
        alignTableCells(cells, columnWidths: columnWidths, rowFont: tableBodyFont, textStorage: textStorage)
    }

    private static func applyHiddenTableSeparator(range: NSRange, to textStorage: NSTextStorage) {
        let style = paragraphStyle(spacingBefore: 0, spacingAfter: 0)
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        // Collapsed + invisible (the visible separator is now the header hairline).
        textStorage.addAttributes([
            .font: NSFont.systemFont(ofSize: 1),
            .foregroundColor: NSColor.clear,
            // The `---|---` separator line is not reading text - exclude from find.
            .mvNonBody: true,
            .paragraphStyle: style
        ], range: range)
    }

    private static func alignTableCells(_ cells: [TableCell], columnWidths: [CGFloat], rowFont: NSFont, letterSpacing: CGFloat = 0, textStorage: NSTextStorage) {
        let columnGap: CGFloat = 30

        let full = textStorage.string as NSString
        for (index, cell) in cells.enumerated() {
            if cell.contentRange.length > 0 {
                textStorage.addAttributes([.font: rowFont], range: cell.contentRange)
                // The visible text is trimmed, but contentRange spans the cell's
                // intra-pipe whitespace too. The kern alignment math measures only
                // `visibleText`, so render that surrounding whitespace at a hidden
                // (~zero) metric - otherwise a sans body row and the monospace
                // header would offset column 0 by their differing space widths.
                hideCellPadding(cell.contentRange, in: full, textStorage: textStorage)
                // Header letter-spacing (mockup `th` letter-spacing 0.4) is applied
                // here, to the VISIBLE cell text only, so its added width is known
                // and can be backed out of the column gap below (keeping the column
                // start aligned with the un-kerned body cell, per the self-test).
                if letterSpacing != 0, let visible = visibleContentRange(of: cell, in: full) {
                    textStorage.addAttributes([.kern: letterSpacing], range: visible)
                }
            }

            guard let trailingPipeRange = cell.trailingPipeRange else { continue }
            let currentWidth = measuredWidth(cell.visibleText, font: rowFont)
            let targetWidth = columnWidths.indices.contains(index) ? columnWidths[index] : currentWidth
            // The letter-spacing kern adds `letterSpacing` after each visible glyph,
            // shifting later columns right; subtract it from the gap so columns stay
            // aligned with the body row (which carries no kern).
            let kernWidth = letterSpacing * CGFloat(cell.visibleText.count)
            let addedSpace = max(columnGap, targetWidth - currentWidth + columnGap) - kernWidth
            // Collapse the pipe glyph to ~zero width (size-1 font); the column gap
            // comes entirely from `.kern`, so a monospace header pipe and a sans
            // body pipe no longer drift the following columns apart.
            var attrs = hiddenMarkupAttributes()
            if index < cells.count - 1 {
                attrs[.kern] = addedSpace
            }
            textStorage.addAttributes(attrs, range: trailingPipeRange)
        }

        if let first = cells.first?.leadingPipeRange {
            // Collapse the leading pipe to ~zero width (size-1 font) so column 0
            // starts at the same x for header (monospace) and body (sans) rows.
            textStorage.addAttributes(hiddenMarkupAttributes(), range: first)
        }
    }

    /// Collapse the leading/trailing whitespace inside a table cell's content
    /// range to a hidden (~zero-width) metric so the visible text starts exactly
    /// at the cell boundary regardless of the row's font. Keeps columns aligned
    /// when the body uses sans and the header uses monospace.
    private static func hideCellPadding(_ contentRange: NSRange, in full: NSString, textStorage: NSTextStorage) {
        guard contentRange.length > 0 else { return }
        // Collapse to a 1pt font so the whitespace contributes ~zero width.
        let collapsed = hiddenMarkupAttributes()
        let s = full.substring(with: contentRange) as NSString
        var leading = 0
        while leading < s.length, isASCIISpaceOrTab(s.character(at: leading)) { leading += 1 }
        // Whole cell is whitespace (empty cell): collapse it all.
        if leading == s.length {
            textStorage.addAttributes(collapsed, range: contentRange)
            return
        }
        var trailing = s.length - 1
        while trailing >= 0, isASCIISpaceOrTab(s.character(at: trailing)) { trailing -= 1 }
        if leading > 0 {
            textStorage.addAttributes(collapsed,
                                      range: NSRange(location: contentRange.location, length: leading))
        }
        let trailCount = (s.length - 1) - trailing
        if trailCount > 0 {
            textStorage.addAttributes(collapsed,
                                      range: NSRange(location: contentRange.location + contentRange.length - trailCount, length: trailCount))
        }
    }

    /// The sub-range of a cell's `contentRange` covering its trimmed visible text
    /// (excludes the leading/trailing intra-pipe whitespace that hideCellPadding
    /// collapses). Used to apply header letter-spacing to only the visible glyphs.
    private static func visibleContentRange(of cell: TableCell, in full: NSString) -> NSRange? {
        let contentRange = cell.contentRange
        guard contentRange.length > 0 else { return nil }
        let s = full.substring(with: contentRange) as NSString
        var leading = 0
        while leading < s.length, isASCIISpaceOrTab(s.character(at: leading)) { leading += 1 }
        if leading == s.length { return nil }   // whitespace-only cell
        var trailing = s.length - 1
        while trailing >= 0, isASCIISpaceOrTab(s.character(at: trailing)) { trailing -= 1 }
        let visibleLength = trailing - leading + 1
        guard visibleLength > 0 else { return nil }
        return NSRange(location: contentRange.location + leading, length: visibleLength)
    }

    private static func isASCIISpaceOrTab(_ c: unichar) -> Bool { c == 32 || c == 9 }

    private struct TableCell {
        let visibleText: String
        let contentRange: NSRange
        let leadingPipeRange: NSRange?
        let trailingPipeRange: NSRange?
    }

    private static func parseTableCells(line: String, lineRange: NSRange) -> [TableCell] {
        let nsLine = line as NSString
        var pipePositions: [Int] = []
        var searchLocation = 0
        while searchLocation < nsLine.length {
            let found = nsLine.range(of: "|", options: [], range: NSRange(location: searchLocation, length: nsLine.length - searchLocation))
            if found.location == NSNotFound { break }
            pipePositions.append(found.location)
            searchLocation = found.location + found.length
        }

        guard !pipePositions.isEmpty else {
            return [
                TableCell(
                    visibleText: line.trimmingCharacters(in: .whitespaces),
                    contentRange: lineRange,
                    leadingPipeRange: nil,
                    trailingPipeRange: nil
                )
            ]
        }

        var boundaries = pipePositions
        if boundaries.first != 0 {
            boundaries.insert(-1, at: 0)
        }
        if boundaries.last != nsLine.length - 1 {
            boundaries.append(nsLine.length)
        }

        var cells: [TableCell] = []
        for index in 0..<(boundaries.count - 1) {
            let startBoundary = boundaries[index]
            let endBoundary = boundaries[index + 1]
            let contentStart = startBoundary + 1
            let contentLength = max(0, endBoundary - contentStart)
            let contentRange = NSRange(location: lineRange.location + contentStart, length: contentLength)
            let text = contentLength > 0 ? nsLine.substring(with: NSRange(location: contentStart, length: contentLength)).trimmingCharacters(in: .whitespaces) : ""
            let leadingPipe = startBoundary >= 0 ? NSRange(location: lineRange.location + startBoundary, length: 1) : nil
            let trailingPipe = endBoundary < nsLine.length && nsLine.character(at: endBoundary) == 124 ? NSRange(location: lineRange.location + endBoundary, length: 1) : nil
            cells.append(TableCell(visibleText: text, contentRange: contentRange, leadingPipeRange: leadingPipe, trailingPipeRange: trailingPipe))
        }

        return cells.filter { !$0.visibleText.isEmpty || $0.trailingPipeRange != nil }
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
