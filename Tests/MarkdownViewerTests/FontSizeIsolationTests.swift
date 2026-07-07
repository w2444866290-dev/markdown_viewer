import AppKit
import Testing
@testable import MarkdownViewer

extension StylerSuites {

    /// #5 (harden): demonstrates the `withBodyPointSize` scoped set + restore around the
    /// process-wide `LiveMarkdownStyler.bodyPointSize` global. Because this suite (and
    /// every styler suite) is serialized under `StylerSuites`, this test's temporary
    /// non-default size can NEVER be observed by another suite. The restore-on-exit
    /// contract is asserted directly so any future "change the font size" test that
    /// routes through the helper cannot leak state.
    @Suite(.serialized)
    struct FontSizeIsolationTests {
        init() { pinBodyPointSize() }

        /// A non-default body size applies to plain body text INSIDE the scope, and the
        /// prior value is restored on exit.
        @Test func scopedSizeAppliesInsideAndRestoresAfter() {
            let before = LiveMarkdownStyler.bodyPointSize
            withBodyPointSize(22) {
                let ts = StylerProbe.styled("Just some plain body words here.")
                guard let i = requireIndex(ts, of: "plain") else { return }
                #expect(StylerProbe.pointSize(ts, i) == 22)
            }
            // Restored on exit - the global did not leak past the scope.
            #expect(LiveMarkdownStyler.bodyPointSize == before)
        }

        /// The pinned default is 15.5, obtained through the same scoped helper.
        @Test func defaultBodySizeIsFifteenPointFive() {
            withBodyPointSize(defaultBodyPointSize) {
                let ts = StylerProbe.styled("Another plain paragraph of body text.")
                guard let i = requireIndex(ts, of: "plain") else { return }
                #expect(StylerProbe.pointSize(ts, i) == 15.5)
            }
        }

        /// Nested scopes restore in LIFO order (inner restores the outer's value).
        @Test func nestedScopesRestoreInOrder() {
            let outerStart = LiveMarkdownStyler.bodyPointSize
            withBodyPointSize(18) {
                #expect(LiveMarkdownStyler.bodyPointSize == 18)
                withBodyPointSize(24) {
                    #expect(LiveMarkdownStyler.bodyPointSize == 24)
                }
                #expect(LiveMarkdownStyler.bodyPointSize == 18)
            }
            #expect(LiveMarkdownStyler.bodyPointSize == outerStart)
        }
    }
}
