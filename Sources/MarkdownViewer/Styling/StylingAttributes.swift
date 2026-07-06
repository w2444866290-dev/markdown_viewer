import AppKit
import UniformTypeIdentifiers

/// Custom icons drawn from the spec's exact SVG paths (ui/Markdown Viewer.dc.html),
/// replacing SF Sy

extension NSAttributedString.Key {
    /// Marks a run inside a fenced code block's body/header → grouped into one
    /// rounded #FAFAFA card with a hairline border (mockup `data-code` div,
    /// Markdown Viewer.dc.html ~294). Boolean `true`.
    static let mvCodeBlock = NSAttributedString.Key("mvCodeBlock")
    /// Marks an inline `code` content run → rounded #F0F0F1 pill (mockup inline
    /// `code` span, Markdown Viewer.dc.html ~292). Boolean `true`.
    static let mvInlineCode = NSAttributedString.Key("mvInlineCode")
    /// Marks a table HEADER row → draws a #ECECEE hairline along its bottom edge
    /// (mockup `th` border-bottom, Markdown Viewer.dc.html ~318). Boolean `true`.
    static let mvTableHeaderRule = NSAttributedString.Key("mvTableHeaderRule")
    /// Marks a table BODY row → draws a #F4F4F5 hairline along its bottom edge
    /// (mockup `td` border-bottom, Markdown Viewer.dc.html ~324). Boolean `true`.
    static let mvTableBodyRule = NSAttributedString.Key("mvTableBodyRule")
    /// Marks a thematic-break line (`---`/`***`/`___`) → draws a 1px #F0F0F1
    /// divider across the text measure (final mockup has no `<hr>` example, so
    /// this uses the Design System divider token, DesignTokens.divider).
    /// Boolean `true`.
    static let mvHorizontalRule = NSAttributedString.Key("mvHorizontalRule")
    /// Marks a run that is NOT clean body/reading text - i.e. everything "所见即所搜"
    /// (find) must EXCLUDE: truly-hidden syntax (heading `#`, emphasis `*`/`_`,
    /// backticks, ``` fence markers, link/image `[]()` syntax, `---` rules, table
    /// pipes/separator) AND dimmed-but-non-body bits (list/quote markers, link URLs,
    /// image alt/path, code-fence language label). Body text (heading/paragraph/
    /// list-item/blockquote/table-cell text, bold/italic text, inline-code AND
    /// fenced-code CONTENT, link label) carries NO `.mvNonBody`. Stamped INTO the
    /// shared non-body attribute dictionaries so it stays in sync with both the
    /// full `apply()` and the scoped `applyIncremental()`; the `setAttributes`
    /// reset at the top of each pass wipes any stale value before re-stamping.
    /// `FindController` walks this attribute to build its body-only search map.
    /// Boolean `true`.
    static let mvNonBody = NSAttributedString.Key("mvNonBody")
}
