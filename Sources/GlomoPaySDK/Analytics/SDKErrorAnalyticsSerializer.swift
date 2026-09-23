import Foundation

enum SDKErrorAnalyticsSerializer {
    static func serialize(_ errors: [SdkError]) -> String {
        let payload = errors.map { error -> [String: Any] in
            var item: [String: Any] = [
                "type": error.type.rawValue,
                "message": AnalyticsSanitizer.text(error.message, limit: 500),
            ]
            if let field = error.field {
                item["field"] = field
            }
            return item
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let serialized = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return serialized
    }
}
