import Foundation
import XCTest
@testable import ClipCore

final class HistoryRepositoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtterClipTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func text(
        _ value: String,
        time: TimeInterval = 100,
        pinned: Bool = false,
        source: String = "Safari"
    ) -> ClipboardItem {
        ClipboardItem(
            kind: .text, text: value, sourceApp: source,
            sourceBundleID: "com.apple.Safari",
            createdAt: Date(timeIntervalSince1970: time),
            lastCopiedAt: Date(timeIntervalSince1970: time),
            isPinned: pinned, fingerprint: "text:\(value)"
        )
    }

    func testPersistsMetadataAndRestrictsPermissions() throws {
        let repository = try HistoryRepository(directory: directory)
        let item = text("A private clipboard value", time: 1_000.125, pinned: true)
        XCTAssertTrue(repository.insert(item))
        XCTAssertNil(repository.lastError)

        let reloaded = try HistoryRepository(directory: directory)
        XCTAssertEqual(reloaded.items, [item])
        let archive = directory.appendingPathComponent("history.json")
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(HistoryArchive.self, from: Data(contentsOf: archive)).version, 1)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(directory.appendingPathComponent("Images")), 0o700)
        XCTAssertEqual(try permissions(archive), 0o600)
    }

    func testDuplicateUpdatesCountAndRecencyWithoutLosingIdentityOrPin() throws {
        let repository = try HistoryRepository(directory: directory)
        let original = text("hello", time: 10)
        repository.insert(original)
        repository.togglePin(id: original.id)
        repository.insert(text("other", time: 20))

        let duplicate = text("hello", time: 30, source: "Notes")
        XCTAssertFalse(repository.insert(duplicate))
        XCTAssertEqual(repository.items.count, 2)
        let refreshed = try XCTUnwrap(repository.items.first)
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertTrue(refreshed.isPinned)
        XCTAssertEqual(refreshed.copyCount, 2)
        XCTAssertEqual(refreshed.createdAt, original.createdAt)
        XCTAssertEqual(refreshed.lastCopiedAt, duplicate.lastCopiedAt)
        XCTAssertEqual(refreshed.sourceApp, "Notes")
        XCTAssertEqual(try HistoryRepository(directory: directory).items, repository.items)
    }

    func testLimitCountsOnlyUnpinnedValuesAndCanBeReducedToZero() throws {
        let repository = try HistoryRepository(directory: directory, limit: 2)
        let pinned = text("keep", time: 1, pinned: true)
        repository.insert(pinned)
        repository.insert(text("old", time: 2))
        repository.insert(text("middle", time: 3))
        repository.insert(text("new", time: 4))
        XCTAssertEqual(repository.items.map(\.text), ["keep", "new", "middle"])

        repository.setLimit(1)
        XCTAssertEqual(repository.items.map(\.text), ["keep", "new"])
        repository.setLimit(0)
        XCTAssertEqual(repository.items, [pinned])
        repository.togglePin(id: pinned.id)
        XCTAssertTrue(repository.items.isEmpty)
        XCTAssertTrue(try HistoryRepository(directory: directory).items.isEmpty)
    }

    func testRepeatedUnpinnedValueMovesToMostRecentPosition() throws {
        let repository = try HistoryRepository(directory: directory)
        let first = text("first", time: 1)
        repository.insert(first)
        repository.insert(text("second", time: 2))
        repository.insert(text("first", time: 3))
        XCTAssertEqual(repository.items.map(\.text), ["first", "second"])
        XCTAssertEqual(repository.items.first?.id, first.id)
        XCTAssertEqual(repository.items.first?.copyCount, 2)
    }

    func testSearchMatchesContentSourceAndFilePathsWithAllRequestedWords() throws {
        let repository = try HistoryRepository(directory: directory)
        let note = text("Résumé project alpha", pinned: true, source: "Notes")
        repository.insert(note)
        let image = ClipboardItem(kind: .image, text: "Product screenshot", sourceApp: "Preview", fingerprint: "image")
        let file = ClipboardItem(kind: .files, filePaths: ["/Users/example/Documents/Invoice.pdf"], sourceApp: "Finder", fingerprint: "file")
        repository.insert(image)
        repository.insert(file)

        XCTAssertEqual(repository.search(query: "resume NOTES", filter: .all), [note])
        XCTAssertTrue(repository.search(query: "alpha missing", filter: .all).isEmpty)
        XCTAssertEqual(repository.search(query: "INVOICE", filter: .files), [file])
        XCTAssertEqual(repository.search(query: "", filter: .images), [image])
        XCTAssertEqual(repository.search(query: "   \n", filter: .pinned), [note])
        XCTAssertEqual(repository.search(query: "", filter: .text), [note])
    }

    func testIdenticalImageBytesShareBlobAndDeletionRemovesOnlyUnreferencedBlobs() throws {
        let repository = try HistoryRepository(directory: directory)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let name = try repository.storeImage(imageData)
        XCTAssertEqual(try repository.storeImage(imageData), name)
        XCTAssertEqual(name.count, 68)
        let first = ClipboardItem(kind: .image, imageFile: name, fingerprint: "first")
        let second = ClipboardItem(kind: .image, imageFile: name, fingerprint: "second")
        repository.insert(first)
        repository.insert(second)
        let imageURL = try XCTUnwrap(repository.imageURL(for: first))
        XCTAssertEqual(try Data(contentsOf: imageURL), imageData)
        XCTAssertEqual(try permissions(imageURL), 0o600)

        repository.remove(id: first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        repository.remove(id: second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertNil(repository.lastError)
    }

    func testEvictionAndClearReclaimImageBlobsWhilePreservingPinnedHistory() throws {
        let repository = try HistoryRepository(directory: directory, limit: 1)
        let name = try repository.storeImage(Data("png".utf8))
        let image = ClipboardItem(
            kind: .image, imageFile: name,
            createdAt: Date(timeIntervalSince1970: 1),
            lastCopiedAt: Date(timeIntervalSince1970: 1),
            fingerprint: "image"
        )
        repository.insert(image)
        let imageURL = try XCTUnwrap(repository.imageURL(for: image))
        repository.insert(text("replacement", time: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))

        let pinned = text("pinned", time: 3, pinned: true)
        repository.insert(pinned)
        repository.clearUnpinned()
        XCTAssertEqual(repository.items, [pinned])
        repository.clearAll()
        XCTAssertTrue(repository.items.isEmpty)
    }

    func testStartupReclaimsOrphansAndAppliesRequestedLimit() throws {
        var repository: HistoryRepository? = try HistoryRepository(directory: directory, limit: 3)
        repository?.insert(text("old", time: 1))
        repository?.insert(text("new", time: 2))
        let orphan = try XCTUnwrap(repository).storeImage(Data("orphan".utf8))
        let orphanURL = directory.appendingPathComponent("Images").appendingPathComponent(orphan)
        repository = nil

        let reloaded = try HistoryRepository(directory: directory, limit: 1)
        XCTAssertEqual(reloaded.items.map(\.text), ["new"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertEqual(try HistoryRepository(directory: directory).items, reloaded.items)
    }

    func testCorruptArchiveAndImagesArePreservedForRecovery() throws {
        let initial = try HistoryRepository(directory: directory)
        let imageName = try initial.storeImage(Data("recoverable image".utf8))
        let invalidData = Data("{\"items\": [broken".utf8)
        let archiveURL = directory.appendingPathComponent("history.json")
        try invalidData.write(to: archiveURL)

        let recovered = try HistoryRepository(directory: directory)
        XCTAssertTrue(recovered.items.isEmpty)
        XCTAssertNotNil(recovered.lastError)
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(contents.first { $0.lastPathComponent.hasPrefix("history.corrupt.") })
        XCTAssertEqual(try Data(contentsOf: backup), invalidData)
        let imageBackup = try XCTUnwrap(contents.first { $0.lastPathComponent.hasPrefix("Images.corrupt.") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageBackup.appendingPathComponent(imageName).path))
        XCTAssertTrue(recovered.insert(text("new beginning")))
        XCTAssertEqual(try HistoryRepository(directory: directory).items, recovered.items)
    }

    func testUnknownArchiveVersionIsRejectedWithoutChangingOriginal() throws {
        _ = try HistoryRepository(directory: directory)
        let data = try JSONEncoder().encode(HistoryArchive(version: 999, items: [text("future")]))
        let archiveURL = directory.appendingPathComponent("history.json")
        try data.write(to: archiveURL)

        XCTAssertThrowsError(try HistoryRepository(directory: directory)) { error in
            guard case HistoryRepositoryError.unsupportedVersion(999) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: archiveURL), data)
    }

    func testFailedAtomicCommitPreservesPreviousInMemoryHistoryAndReportsError() throws {
        let repository = try HistoryRepository(directory: directory)
        let original = text("original")
        repository.insert(original)
        let archiveURL = directory.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: archiveURL)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)

        XCTAssertFalse(repository.insert(text("cannot persist", time: 200)))
        XCTAssertEqual(repository.items, [original])
        XCTAssertNotNil(repository.lastError)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(temporaryFiles.isEmpty)

        try FileManager.default.removeItem(at: archiveURL)
        XCTAssertTrue(repository.insert(text("can persist", time: 300)))
        XCTAssertNil(repository.lastError)
    }

    func testImageLookupRejectsPathTraversal() throws {
        let repository = try HistoryRepository(directory: directory)
        for filename in ["../secret.png", "/etc/passwd", "..", ".", "", "dir\\image.png"] {
            let item = ClipboardItem(kind: .image, imageFile: filename, fingerprint: filename)
            XCTAssertNil(repository.imageURL(for: item))
        }
    }

    func testTitlesSummarizeMultilineTextAndMultipleFiles() {
        XCTAssertEqual(text("\n  Hello\nworld").title, "Hello")
        let files = ClipboardItem(kind: .files, filePaths: ["/tmp/one.png", "/tmp/two.png"], fingerprint: "files")
        XCTAssertEqual(files.title, "one.png 等 2 个文件")
    }

    func testMetadataBudgetCountsTextAndFilePathsAndAlwaysKeepsPins() throws {
        let repository = try HistoryRepository(directory: directory)
        let payload = String(repeating: "x", count: 6 * 1024 * 1024)
        let pinned = ClipboardItem(kind: .text, text: payload, lastCopiedAt: Date(timeIntervalSince1970: 1), isPinned: true, fingerprint: "metadata-pin")
        let older = ClipboardItem(kind: .text, text: payload, lastCopiedAt: Date(timeIntervalSince1970: 2), fingerprint: "metadata-older")
        let recent = ClipboardItem(kind: .text, text: payload, lastCopiedAt: Date(timeIntervalSince1970: 3), fingerprint: "metadata-recent")
        for item in [pinned, older, recent] { repository.insert(item) }
        XCTAssertEqual(repository.items.map(\.id), [pinned.id, recent.id])

        let paths = ClipboardItem(kind: .files, filePaths: [String(repeating: "p", count: 5 * 1024 * 1024)], lastCopiedAt: Date(timeIntervalSince1970: 4), fingerprint: "metadata-paths")
        repository.insert(paths)
        XCTAssertEqual(repository.items.map(\.id), [pinned.id, paths.id])

        let oversizedPin = ClipboardItem(kind: .text, text: String(repeating: "z", count: 17 * 1024 * 1024), isPinned: true, fingerprint: "metadata-oversized-pin")
        repository.insert(oversizedPin)
        XCTAssertEqual(Set(repository.items.map(\.id)), Set([pinned.id, oversizedPin.id]))
        XCTAssertTrue(repository.items.allSatisfy(\.isPinned))
        XCTAssertNil(repository.lastError)
        XCTAssertEqual(try HistoryRepository(directory: directory).items, repository.items)
    }

    func testImageBudgetCountsUniqueBlobsAndAlwaysKeepsPins() throws {
        let repository = try HistoryRepository(directory: directory)
        func image(_ filename: String, time: TimeInterval, pinned: Bool = false) -> ClipboardItem {
            ClipboardItem(kind: .image, imageFile: filename, lastCopiedAt: Date(timeIntervalSince1970: time), isPinned: pinned, fingerprint: UUID().uuidString)
        }
        let firstName = try repository.storeImage(Data(repeating: 1, count: 40 * 1024 * 1024))
        let pinned = image(firstName, time: 1, pinned: true)
        repository.insert(pinned)
        let olderName = try repository.storeImage(Data(repeating: 2, count: 40 * 1024 * 1024))
        let older = image(olderName, time: 2)
        repository.insert(older)
        let recentName = try repository.storeImage(Data(repeating: 3, count: 40 * 1024 * 1024))
        let recent = image(recentName, time: 3)
        repository.insert(recent)
        XCTAssertEqual(repository.items.map(\.id), [pinned.id, recent.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(repository.imageURL(for: older)).path))

        let shared = image(firstName, time: 4)
        repository.insert(shared)
        XCTAssertEqual(repository.items.map(\.id), [pinned.id, shared.id, recent.id])
        XCTAssertEqual(try HistoryRepository(directory: directory).items, repository.items)

        repository.togglePin(id: recent.id)
        let extraName = try repository.storeImage(Data(repeating: 4, count: 30 * 1024 * 1024))
        let extraPin = image(extraName, time: 5, pinned: true)
        repository.insert(extraPin)
        XCTAssertEqual(Set(repository.items.map(\.id)), Set([pinned.id, recent.id, extraPin.id]))
        XCTAssertTrue(repository.items.allSatisfy(\.isPinned))
        XCTAssertNil(repository.lastError)
        XCTAssertEqual(try HistoryRepository(directory: directory).items, repository.items)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
