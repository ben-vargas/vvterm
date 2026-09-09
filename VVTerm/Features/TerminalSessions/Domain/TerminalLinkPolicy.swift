import Foundation

nonisolated enum TerminalLinkPolicy {
    static let maximumURLByteCount = 65_536

    static func destination(_ text: String) -> URL? {
        guard !text.isEmpty, text.utf8.count <= maximumURLByteCount,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
                      || (0x202A...0x202E).contains($0.value)
                      || (0x2066...0x2069).contains($0.value)
              }),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else { return nil }
        case "file":
            guard let path = components.percentEncodedPath.removingPercentEncoding,
                  path.hasPrefix("/"),
                  path == path.trimmingCharacters(in: .whitespacesAndNewlines),
                  components.user == nil, components.password == nil, components.port == nil,
                  components.query == nil, components.fragment == nil,
                  !path.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                          || (0x202A...0x202E).contains($0.value)
                          || (0x2066...0x2069).contains($0.value)
                  })
            else { return nil }
        case "mailto":
            guard !components.path.isEmpty else { return nil }
        default:
            return nil
        }
        return components.url
    }
}
