@testable import AutoCompCore
import Foundation
import XCTest

final class AutoCompUserDirectoriesTests: XCTestCase {
    func testApplicationSupportDirectoryUsesHomeLibraryPathWithoutFolderLookup() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        let appSupport = AutoCompUserDirectories.appSupportDirectory(homeDirectory: home)

        XCTAssertEqual(appSupport.path, "/Users/test/Library/Application Support/AutoComp")
    }

    func testLocalModelCatalogDefaultDirectoryUsesSharedAutoCompSupportDirectory() {
        XCTAssertTrue(LocalModelCatalog.defaultModelsDirectoryURL.path.hasSuffix("/Library/Application Support/AutoComp/Models"))
    }
}
