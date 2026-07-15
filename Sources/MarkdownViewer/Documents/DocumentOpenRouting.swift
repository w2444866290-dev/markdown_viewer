import Foundation
import UniformTypeIdentifiers

enum DocumentOpenAdmission: Equatable, Sendable {
    case openPanel
    case system
    case drop

    var allowsDirectories: Bool {
        self != .drop
    }

    func acceptsFile(_ url: URL) -> Bool {
        let filenameExtension = url.pathExtension.lowercased()
        switch self {
        case .drop:
            return DocumentFormat.dropExtensions.contains(filenameExtension)
        case .openPanel, .system:
            return DocumentFormat(url: url).isOpenable
        }
    }

    var unsupportedMessage: String {
        switch self {
        case .drop:
            return "仅支持 Markdown / 文本文件"
        case .openPanel, .system:
            return "不支持此文件类型"
        }
    }
}

enum DocumentOpenResult: Equatable {
    case cancelled
    case openedFile(UUID)
    case activatedExisting(UUID)
    case openedDirectory(URL)
    case rejectedUnsupported
    case failedToRead
}

enum DocumentDropResolution: Equatable {
    case fileURL(URL)
    case invalid
}

/// Owns one-shot delivery for native drop providers.
///
/// SwiftUI normally invokes `onDrop` once, and `NSItemProvider` normally completes
/// once. Keeping both guarantees explicit prevents duplicate tab activation or
/// duplicate rejection feedback if either callback is delivered more than once.
@MainActor
final class DocumentDropCoordinator {
    private final class SendableProviderBox: @unchecked Sendable {
        let provider: NSItemProvider

        init(_ provider: NSItemProvider) {
            self.provider = provider
        }
    }

    private final class SendableDropItemBox: @unchecked Sendable {
        let item: Any?

        init(_ item: Any?) {
            self.item = item
        }
    }

    private final class ProviderEntry {
        weak var provider: AnyObject?
        var resolved = false

        init(provider: AnyObject) {
            self.provider = provider
        }
    }

    private var providers: [ObjectIdentifier: ProviderEntry] = [:]

    func claim(provider: AnyObject) -> Bool {
        pruneReleasedProviders()
        let identifier = ObjectIdentifier(provider)
        if let entry = providers[identifier], entry.provider === provider {
            return false
        }
        providers[identifier] = ProviderEntry(provider: provider)
        return true
    }

    func resolve(item: Any?, provider: AnyObject) -> DocumentDropResolution? {
        let identifier = ObjectIdentifier(provider)
        guard let entry = providers[identifier],
              entry.provider === provider,
              !entry.resolved else {
            return nil
        }
        entry.resolved = true
        guard let url = Self.fileURL(from: item), url.isFileURL else {
            return .invalid
        }
        return .fileURL(url)
    }

    @discardableResult
    func handle(providers: [NSItemProvider], manager: DocumentManager) -> Bool {
        guard let provider = providers.first else { return false }
        guard claim(provider: provider) else { return true }
        let providerBox = SendableProviderBox(provider)

        provider.loadItem(
            forTypeIdentifier: UTType.fileURL.identifier,
            options: nil
        ) { [weak self, weak manager, providerBox] item, _ in
            let itemBox = SendableDropItemBox(item)
            DispatchQueue.main.async {
                guard let self,
                      let resolution = self.resolve(
                        item: itemBox.item,
                        provider: providerBox.provider
                      ) else {
                    return
                }
                switch resolution {
                case .fileURL(let url):
                    _ = manager?.openSelection(url, admission: .drop)
                case .invalid:
                    Toaster.shared.flash("无法打开文件")
                }
            }
        }
        return true
    }

    private func pruneReleasedProviders() {
        providers = providers.filter { $0.value.provider != nil }
    }

    private static func fileURL(from item: Any?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let string = item as? String {
            return fileURL(from: string)
        }
        if let string = item as? NSString {
            return fileURL(from: string as String)
        }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                return url
            }
            return fileURL(from: String(decoding: data, as: UTF8.self))
        }
        return nil
    }

    private static func fileURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.controlCharacters)
        )
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return nil
    }
}
