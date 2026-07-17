import Foundation

public final class MirroredUserDefaults: @unchecked Sendable {
    public static let appSuiteNames = ["com.autocomp.AutoComp", "AutoComp"]

    private let stores: [UserDefaults]

    public init(
        primary: UserDefaults = .standard,
        mirrors: [UserDefaults]? = nil
    ) {
        let resolvedMirrors = mirrors ?? Self.defaultMirrors(for: primary)
        stores = [primary] + resolvedMirrors.filter { candidate in
            candidate !== primary
        }
    }

    public func object(forKey key: String) -> Any? {
        firstValue { $0.object(forKey: key) }
    }

    public func string(forKey key: String) -> String? {
        firstValue { $0.string(forKey: key) }
    }

    public func data(forKey key: String) -> Data? {
        firstValue { $0.data(forKey: key) }
    }

    public func dictionary(forKey key: String) -> [String: Any]? {
        firstValue { $0.dictionary(forKey: key) }
    }

    public func bool(forKey key: String) -> Bool {
        stores.first { $0.object(forKey: key) != nil }?.bool(forKey: key) ?? false
    }

    public func integer(forKey key: String) -> Int {
        stores.first { $0.object(forKey: key) != nil }?.integer(forKey: key) ?? 0
    }

    public func set(_ value: Any?, forKey key: String) {
        for store in stores {
            store.set(value, forKey: key)
        }
    }

    public func removeObject(forKey key: String) {
        for store in stores {
            store.removeObject(forKey: key)
        }
    }

    public func synchronize() {
        for store in stores {
            store.synchronize()
        }
    }

    public func decode<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String,
        decoder: JSONDecoder = JSONDecoder()
    ) -> Value? {
        guard let data = data(forKey: key) else {
            return nil
        }
        return try? decoder.decode(type, from: data)
    }

    public func encode<Value: Encodable>(
        _ value: Value,
        forKey key: String,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        set(try encoder.encode(value), forKey: key)
    }

    private func firstValue<Value>(_ read: (UserDefaults) -> Value?) -> Value? {
        for store in stores {
            if let value = read(store) {
                return value
            }
        }
        return nil
    }

    private static func defaultMirrors(for primary: UserDefaults) -> [UserDefaults] {
        guard primary === UserDefaults.standard else {
            return []
        }
        return appSuiteNames.compactMap(UserDefaults.init(suiteName:))
    }
}
