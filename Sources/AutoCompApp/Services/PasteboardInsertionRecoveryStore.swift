import Foundation

struct PasteboardInsertionRecoverySnapshot: Codable, Equatable {
    let id: String
    let createdAt: Date
    let previousItems: [PreservedPasteboardItem]?
}

final class PasteboardInsertionRecoveryStore: @unchecked Sendable {
    private let snapshotURL: URL
    private let recoveryWindow: TimeInterval
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        directory: URL = PasteboardInsertionRecoveryStore.defaultDirectory,
        recoveryWindow: TimeInterval = 5 * 60,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { Date() }
    ) {
        self.snapshotURL = directory.appendingPathComponent("pending-pasteboard-insertion.json", isDirectory: false)
        self.recoveryWindow = recoveryWindow
        self.fileManager = fileManager
        self.now = now
    }

    func save(_ snapshot: PasteboardInsertionRecoverySnapshot) throws {
        try fileManager.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotURL, options: [.atomic])
    }

    func loadFreshSnapshot() -> PasteboardInsertionRecoverySnapshot? {
        guard let snapshot = loadRawSnapshot() else {
            return nil
        }

        guard now().timeIntervalSince(snapshot.createdAt) <= recoveryWindow else {
            try? delete(matchingID: snapshot.id)
            GeometryDebug.log("pasteboard-recovery skipped reason=expired")
            return nil
        }

        return snapshot
    }

    func hasPendingSnapshot() -> Bool {
        loadRawSnapshot() != nil
    }

    func delete(matchingID id: String? = nil) throws {
        if let id,
           loadRawSnapshot()?.id != id {
            return
        }

        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return
        }
        try fileManager.removeItem(at: snapshotURL)
    }

    private func loadRawSnapshot() -> PasteboardInsertionRecoverySnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path),
              let data = try? Data(contentsOf: snapshotURL) else {
            return nil
        }

        guard let snapshot = try? JSONDecoder().decode(PasteboardInsertionRecoverySnapshot.self, from: data) else {
            try? fileManager.removeItem(at: snapshotURL)
            GeometryDebug.log("pasteboard-recovery skipped reason=unreadable-snapshot")
            return nil
        }
        return snapshot
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoComp", isDirectory: true)
            .appendingPathComponent("PasteboardInsertionRecovery", isDirectory: true)
    }
}
