import Foundation

/// Resolves local links against the document, never the process working directory.
enum MarkdownLinkResolver {
    static func resolve(_ destination: String, documentURL: URL?) -> URL? {
        guard !destination.isEmpty else { return nil }
        // Encode Unicode and spaces once while retaining existing URL escapes.
        let allowed = CharacterSet.urlFragmentAllowed.union(
            CharacterSet(charactersIn: "%#[]")
        )
        guard let encoded = destination.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }

        if let url = URL(string: encoded), url.scheme != nil {
            return url.isFileURL ? url.standardizedFileURL : url
        }

        let base: URL
        let relative: String
        if destination == "~" { return FileManager.default.homeDirectoryForCurrentUser }
        if destination.hasPrefix("~/") {
            base = FileManager.default.homeDirectoryForCurrentUser
            relative = String(encoded.dropFirst(2))
        } else if destination.hasPrefix("/") {
            base = URL(fileURLWithPath: "/", isDirectory: true)
            relative = encoded
        } else if let documentURL, documentURL.isFileURL {
            base = documentURL.deletingLastPathComponent()
            relative = encoded
        } else {
            return nil
        }

        return URL(string: relative, relativeTo: base)?.absoluteURL.standardizedFileURL
    }
}
