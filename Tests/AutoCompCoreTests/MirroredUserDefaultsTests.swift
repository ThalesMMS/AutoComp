@testable import AutoCompCore
import Foundation
import XCTest

final class MirroredUserDefaultsTests: XCTestCase {
    private struct Fixture: Codable, Equatable {
        let value: String
    }

    func testReadsPrimaryBeforeMirrorsAndFallsBackToMirror() {
        let stores = makeStores()
        defer { stores.removeDomains() }
        stores.primary.set("primary", forKey: "value")
        stores.mirror.set("mirror", forKey: "value")
        let defaults = MirroredUserDefaults(primary: stores.primary, mirrors: [stores.mirror])

        XCTAssertEqual(defaults.string(forKey: "value"), "primary")

        stores.primary.removeObject(forKey: "value")
        XCTAssertEqual(defaults.string(forKey: "value"), "mirror")
    }

    func testWritesRemovesAndEncodesAcrossPrimaryAndMirrors() throws {
        let stores = makeStores()
        defer { stores.removeDomains() }
        let defaults = MirroredUserDefaults(primary: stores.primary, mirrors: [stores.mirror])

        defaults.set(42, forKey: "count")
        try defaults.encode(Fixture(value: "shared"), forKey: "fixture")

        XCTAssertEqual(stores.primary.integer(forKey: "count"), 42)
        XCTAssertEqual(stores.mirror.integer(forKey: "count"), 42)
        XCTAssertEqual(defaults.decode(Fixture.self, forKey: "fixture"), Fixture(value: "shared"))
        XCTAssertNotNil(stores.primary.data(forKey: "fixture"))
        XCTAssertNotNil(stores.mirror.data(forKey: "fixture"))

        defaults.removeObject(forKey: "count")
        XCTAssertNil(stores.primary.object(forKey: "count"))
        XCTAssertNil(stores.mirror.object(forKey: "count"))
    }

    func testCustomPrimaryDoesNotImplicitlyUseAppSuites() {
        let stores = makeStores()
        defer { stores.removeDomains() }
        stores.mirror.set("mirror", forKey: "value")

        let defaults = MirroredUserDefaults(primary: stores.primary)

        XCTAssertNil(defaults.string(forKey: "value"))
        defaults.set("primary", forKey: "value")
        XCTAssertEqual(stores.primary.string(forKey: "value"), "primary")
        XCTAssertEqual(stores.mirror.string(forKey: "value"), "mirror")
    }

    private func makeStores() -> TestStores {
        let primaryName = "MirroredUserDefaultsTests.primary.\(UUID().uuidString)"
        let mirrorName = "MirroredUserDefaultsTests.mirror.\(UUID().uuidString)"
        return TestStores(
            primaryName: primaryName,
            mirrorName: mirrorName,
            primary: UserDefaults(suiteName: primaryName)!,
            mirror: UserDefaults(suiteName: mirrorName)!
        )
    }
}

private struct TestStores {
    let primaryName: String
    let mirrorName: String
    let primary: UserDefaults
    let mirror: UserDefaults

    func removeDomains() {
        primary.removePersistentDomain(forName: primaryName)
        mirror.removePersistentDomain(forName: mirrorName)
    }
}
