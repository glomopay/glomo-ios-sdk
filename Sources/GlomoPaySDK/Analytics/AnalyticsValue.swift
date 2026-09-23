import CoreFoundation
import Foundation

enum AnalyticsValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnalyticsValue])
    case object([String: AnalyticsValue])

    init?(jsonValue: Any) {
        switch jsonValue {
        case is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .integer(Int64(value))
        case let value as Int64:
            self = .integer(value)
        case let value as Double:
            self = .double(value)
        case let value as Float:
            self = .double(Double(value))
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if CFNumberIsFloatType(value) {
                self = .double(value.doubleValue)
            } else {
                self = .integer(value.int64Value)
            }
        case let value as [Any]:
            let values = value.compactMap(Self.init(jsonValue:))
            guard values.count == value.count else { return nil }
            self = .array(values)
        case let value as [String: Any]:
            var values: [String: AnalyticsValue] = [:]
            for (key, item) in value {
                guard let converted = Self(jsonValue: item) else { return nil }
                values[key] = converted
            }
            self = .object(values)
        default:
            return nil
        }
    }

    var jsonObject: Any {
        switch self {
        case let .string(value): return value
        case let .integer(value): return value
        case let .double(value): return value
        case let .bool(value): return value
        case .null: return NSNull()
        case let .array(values): return values.map(\.jsonObject)
        case let .object(values): return values.mapValues(\.jsonObject)
        }
    }

    static func properties(from values: [String: Any]) -> [String: AnalyticsValue] {
        values.reduce(into: [:]) { output, item in
            guard let value = AnalyticsValue(jsonValue: item.value) else { return }
            output[item.key] = value
        }
    }
}
