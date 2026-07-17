import Foundation

struct SessionTTLCacheStats: Equatable {
    private(set) var hits = 0
    private(set) var misses = 0
    private(set) var negativeHits = 0

    mutating func recordHit() { hits += 1 }
    mutating func recordMiss() { misses += 1 }
    mutating func recordNegativeHit() { negativeHits += 1 }
}

enum SessionTTLCacheLookup<Value> {
    case hit(Value)
    case negativeHit
    case miss
}

final class SessionTTLCache<Key: Equatable, Value> {
    private struct Entry {
        let key: Key
        let expiresAt: Date
        let value: Value?
    }

    private let ttl: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var entry: Entry?
    private var storedStats = SessionTTLCacheStats()

    var stats: SessionTTLCacheStats {
        lock.withLock { storedStats }
    }

    init(ttl: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.ttl = max(0, ttl)
        self.now = now
    }

    func lookup(_ key: Key) -> SessionTTLCacheLookup<Value> {
        lock.withLock {
            guard let entry, entry.key == key, now() < entry.expiresAt else {
                self.entry = nil
                storedStats.recordMiss()
                return .miss
            }
            guard let value = entry.value else {
                storedStats.recordNegativeHit()
                return .negativeHit
            }
            storedStats.recordHit()
            return .hit(value)
        }
    }

    func store(_ value: Value?, for key: Key) {
        lock.withLock {
            entry = Entry(key: key, expiresAt: now().addingTimeInterval(ttl), value: value)
        }
    }

    func reset() {
        lock.withLock {
            entry = nil
        }
    }
}
