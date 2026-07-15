import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MarkdownViewer

@Suite
struct DocumentFormatTests {
    @Test
    func markdownCompatibleFormatsRenderMarkdownAndSupportPreview() {
        for filenameExtension in ["md", "markdown", "mdx"] {
            let format = DocumentFormat(filenameExtension: filenameExtension)
            #expect(format == .markdown)
            #expect(format.isOpenable)
            #expect(format.isMarkdownRendered)
            #expect(format.supportsPreview)
        }
    }

    @Test
    func plainTextIsOpenableSourceWithoutPreview() {
        let format = DocumentFormat(url: fileURL("notes.txt"))

        #expect(format == .plainSource)
        #expect(format.isOpenable)
        #expect(!format.isMarkdownRendered)
        #expect(!format.supportsPreview)
    }

    @Test
    func classificationNormalizesUppercaseWhitespaceAndLeadingDots() {
        #expect(DocumentFormat(url: fileURL("README.MDX")) == .markdown)
        #expect(DocumentFormat(url: fileURL("CONFIG.YAML")) == .plainSource)
        #expect(DocumentFormat(filenameExtension: "  .MaRkDoWn  ") == .markdown)
        #expect(DocumentFormat(filenameExtension: "..TXT") == .plainSource)
    }

    @Test
    func everyExistingSourceExtensionRemainsOpenablePlainSource() {
        let extensions = [
            "mdown", "mkd",
            "txt", "text",
            "yaml", "yml", "json", "toml",
            "swift", "sh", "py", "js", "ts",
            "html", "css", "xml",
            "rb", "go", "rs", "java", "kt",
        ]

        #expect(Set(extensions) == DocumentFormat.plainSourceExtensions)
        for filenameExtension in extensions {
            let format = DocumentFormat(filenameExtension: filenameExtension)
            #expect(format == .plainSource)
            #expect(format.isOpenable)
            #expect(!format.isMarkdownRendered)
            #expect(!format.supportsPreview)
        }
    }

    @Test
    func unsupportedAndExtensionlessFilesAreRejected() {
        for filename in ["image.png", "manual.pdf", "archive.zip", "App.dmg", "LICENSE"] {
            let format = DocumentFormat(url: fileURL(filename))
            #expect(format == .unsupported)
            #expect(!format.isOpenable)
            #expect(!format.isMarkdownRendered)
            #expect(!format.supportsPreview)
        }
    }

    @Test
    func nilURLRepresentsUntitledMarkdownDocument() {
        let format = DocumentFormat(url: nil)

        #expect(format == .markdown)
        #expect(format.isOpenable)
        #expect(format.isMarkdownRendered)
        #expect(format.supportsPreview)
    }

    @Test
    func openPanelExtensionsExactlyCoverSupportedFormats() {
        let expected = DocumentFormat.markdownExtensions
            .union(DocumentFormat.plainSourceExtensions)

        #expect(DocumentFormat.openableExtensions == expected)
        #expect(DocumentFormat.openPanelFilenameExtensions == expected)
        #expect(expected.contains("mdx"))
        #expect(expected.contains("txt"))
        #expect(!expected.contains("png"))
    }

    @Test
    func openPanelContentTypesContainEveryAvailableUniqueUTType() {
        let expectedIdentifiers = Set(
            DocumentFormat.openPanelFilenameExtensions.compactMap {
                UTType(filenameExtension: $0)?.identifier
            }
        )
        let actualIdentifiers = DocumentFormat.openPanelContentTypes.map(\.identifier)

        #expect(Set(actualIdentifiers) == expectedIdentifiers)
        #expect(actualIdentifiers.count == Set(actualIdentifiers).count)
    }

    private func fileURL(_ filename: String) -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
