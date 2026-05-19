import AutoCompCore
import XCTest

final class SecurePersonalizationStoreTests: XCTestCase {
    func testDeleteAllRemovesEncryptedRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompTests-\(UUID().uuidString)", isDirectory: true)
        let store = SecurePersonalizationStore(
            directory: directory,
            service: "com.autocomp.tests.\(UUID().uuidString)"
        )

        try store.append("hello", appBundleID: "com.apple.TextEdit", domain: nil)
        XCTAssertEqual(store.recordCount(), 1)

        try store.deleteAll()
        XCTAssertEqual(store.recordCount(), 0)
    }
}
