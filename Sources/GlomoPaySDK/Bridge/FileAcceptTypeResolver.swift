import Foundation
import UniformTypeIdentifiers

@available(iOS 14.0, macOS 11.0, *)
enum FileAcceptTypeResolver {
    static func contentTypes(for accept: String) -> [UTType] {
        let resolved = accept
            .split(separator: ",")
            .compactMap { contentType(for: String($0)) }
            .reduce(into: [UTType]()) { result, type in
                guard !result.contains(where: { $0.identifier == type.identifier }) else { return }
                result.append(type)
            }

        return resolved.isEmpty ? [.item] : resolved
    }

    private static func contentType(for rawValue: String) -> UTType? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        switch value {
        case "image/*": return .image
        case "audio/*": return .audio
        case "video/*": return .movie
        default:
            if value.hasPrefix(".") {
                return UTType(filenameExtension: String(value.dropFirst()))
            }
            return UTType(mimeType: value)
        }
    }
}
