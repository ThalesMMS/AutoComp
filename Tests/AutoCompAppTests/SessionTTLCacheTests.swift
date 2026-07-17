@testable import AutoCompApp
import XCTest

final class SessionTTLCacheTests: XCTestCase {
    func testCachesPositiveAndNegativeResultsUntilTTLThenExpires() {
        var now = Date(timeIntervalSince1970: 100)
        let cache = SessionTTLCache<String, Int>(ttl: 1, now: { now })

        XCTAssertMiss(cache.lookup("field"))
        cache.store(nil, for: "field")
        XCTAssertNegativeHit(cache.lookup("field"))
        now = now.addingTimeInterval(2)
        XCTAssertMiss(cache.lookup("field"))
        cache.store(42, for: "field")
        XCTAssertHit(cache.lookup("field"), value: 42)

        XCTAssertEqual(cache.stats, SessionTTLCacheStats(hits: 1, misses: 2, negativeHits: 1))
    }

    func testDifferentSessionKeyInvalidatesCachedValue() {
        let cache = SessionTTLCache<String, Int>(ttl: 1)
        cache.store(1, for: "field-a")

        XCTAssertMiss(cache.lookup("field-b"))
    }

    private func XCTAssertMiss<T>(_ lookup: SessionTTLCacheLookup<T>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .miss = lookup else { return XCTFail("Expected miss", file: file, line: line) }
    }

    private func XCTAssertNegativeHit<T>(_ lookup: SessionTTLCacheLookup<T>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .negativeHit = lookup else { return XCTFail("Expected negative hit", file: file, line: line) }
    }

    private func XCTAssertHit<T: Equatable>(_ lookup: SessionTTLCacheLookup<T>, value: T, file: StaticString = #filePath, line: UInt = #line) {
        guard case .hit(let actual) = lookup else { return XCTFail("Expected hit", file: file, line: line) }
        XCTAssertEqual(actual, value, file: file, line: line)
    }
}
