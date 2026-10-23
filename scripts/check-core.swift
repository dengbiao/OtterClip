import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(description: message) }
    return value
}

private func sample(_ value: String, _ time: TimeInterval = 100, pinned: Bool = false, source: String = "Safari") -> ClipboardItem {
    ClipboardItem(
        kind: .text, text: value, sourceApp: source, sourceBundleID: "com.apple.Safari",
        createdAt: Date(timeIntervalSince1970: time), lastCopiedAt: Date(timeIntervalSince1970: time),
        isPinned: pinned, fingerprint: "text:\(value)"
    )
}

private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try require(attributes[.posixPermissions] as? NSNumber, "missing POSIX permissions").intValue & 0o777
}

@main
private enum CoreChecks {
    static func main() {
        let checks: [(String, (URL) throws -> Void)] = [
            ("persistence and private permissions", persistence),
            ("duplicate identity, pin, count and source", duplicates),
            ("recency ordering", recency),
            ("unpinned capacity and zero limit", limits),
            ("search and type filters", search),
            ("content-addressed images and reference cleanup", images),
            ("eviction and clearing", clearing),
            ("startup limit and orphan cleanup", startup),
            ("corrupt metadata and image recovery", corruption),
            ("future format preservation", futureFormat),
            ("failed atomic commit rollback", failedCommit),
            ("safe image filenames", safePaths),
            ("display titles", titles),
            ("metadata budget and pin protection", metadataBudget),
            ("unique image budget and pin protection", imageBudget)
        ]
        var failures = 0
        for (name, check) in checks {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OtterClipCoreChecks-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try check(directory)
                print("PASS \(name)")
            } catch {
                failures += 1
                fputs("FAIL \(name): \(error)\n", stderr)
            }
        }
        print("\(checks.count - failures)/\(checks.count) core checks passed")
        if failures > 0 { exit(1) }
    }

    private static func persistence(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory)
        let item = sample("A private clipboard value", 1_000.125, pinned: true)
        try expect(repository.insert(item), "new item rejected")
        try expect(repository.lastError == nil, "unexpected write error")
        try expect(HistoryRepository(directory: directory).items == [item], "reload changed history")
        let archiveURL = directory.appendingPathComponent("history.json")
        let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: archiveURL))
        try expect(archive.version == 1, "wrong archive version")
        try expect(permissions(directory) == 0o700, "repository directory is not private")
        try expect(permissions(directory.appendingPathComponent("Images")) == 0o700, "image directory is not private")
        try expect(permissions(archiveURL) == 0o600, "metadata is not private")
    }

    private static func duplicates(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory)
        let original = sample("hello", 10)
        repository.insert(original)
        repository.togglePin(id: original.id)
        repository.insert(sample("other", 20))
        let duplicate = sample("hello", 30, source: "Notes")
        try expect(!repository.insert(duplicate), "duplicate reported as new")
        let refreshed = try require(repository.items.first, "missing original")
        try expect(repository.items.count == 2, "duplicate added another row")
        try expect(refreshed.id == original.id && refreshed.isPinned, "duplicate lost identity or pin")
        try expect(refreshed.copyCount == 2, "copy count did not increase")
        try expect(refreshed.createdAt == original.createdAt, "created date changed")
        try expect(refreshed.lastCopiedAt == duplicate.lastCopiedAt, "last copied date not updated")
        try expect(refreshed.sourceApp == "Notes", "source not updated")
        try expect(HistoryRepository(directory: directory).items == repository.items, "duplicate change not persisted")
    }

    private static func recency(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory)
        let first = sample("first", 1)
        repository.insert(first)
        repository.insert(sample("second", 2))
        repository.insert(sample("first", 3))
        try expect(repository.items.map(\.text) == ["first", "second"], "duplicate did not move first")
        try expect(repository.items.first?.id == first.id, "duplicate identity changed")
    }

    private static func limits(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory, limit: 2)
        let pinned = sample("keep", 1, pinned: true)
        repository.insert(pinned)
        for (time, value) in ["old", "middle", "new"].enumerated() { repository.insert(sample(value, Double(time + 2))) }
        try expect(repository.items.map(\.text) == ["keep", "new", "middle"], "limit evicted wrong history")
        repository.setLimit(1)
        try expect(repository.items.map(\.text) == ["keep", "new"], "reduced limit not applied")
        repository.setLimit(0)
        try expect(repository.items == [pinned], "zero limit removed pin or kept unpinned item")
        repository.togglePin(id: pinned.id)
        try expect(repository.items.isEmpty, "unpin did not apply zero limit")
    }

    private static func search(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory)
        let note = sample("Résumé project alpha", pinned: true, source: "Notes")
        let image = ClipboardItem(kind: .image, text: "Product screenshot", sourceApp: "Preview", fingerprint: "image")
        let file = ClipboardItem(kind: .files, filePaths: ["/Users/example/Documents/Invoice.pdf"], sourceApp: "Finder", fingerprint: "file")
        for item in [note, image, file] { repository.insert(item) }
        try expect(repository.search(query: "resume NOTES", filter: .all) == [note], "case/diacritic/source search failed")
        try expect(repository.search(query: "alpha missing", filter: .all).isEmpty, "query words are not combined")
        try expect(repository.search(query: "INVOICE", filter: .files) == [file], "file path search failed")
        try expect(repository.search(query: "", filter: .images) == [image], "image filter failed")
        try expect(repository.search(query: "   \n", filter: .pinned) == [note], "pinned filter failed")
        try expect(repository.search(query: "", filter: .text) == [note], "text filter failed")
    }

    private static func images(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory)
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let name = try repository.storeImage(data)
        try expect(repository.storeImage(data) == name, "same image bytes not deduplicated")
        try expect(name.count == 68, "image name is not SHA256 with PNG extension")
        let first = ClipboardItem(kind: .image, imageFile: name, fingerprint: "first")
        let second = ClipboardItem(kind: .image, imageFile: name, fingerprint: "second")
        repository.insert(first)
        repository.insert(second)
        let url = try require(repository.imageURL(for: first), "missing image URL")
        try expect(Data(contentsOf: url) == data, "image bytes changed")
        try expect(permissions(url) == 0o600, "image is not private")
        repository.remove(id: first.id)
        try expect(FileManager.default.fileExists(atPath: url.path), "still referenced image removed")
        repository.remove(id: second.id)
        try expect(!FileManager.default.fileExists(atPath: url.path), "unreferenced image kept")
    }

    private static func clearing(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory, limit: 1)
        let name = try repository.storeImage(Data("image".utf8))
        let image = ClipboardItem(kind: .image, imageFile: name, createdAt: Date(timeIntervalSince1970: 1), lastCopiedAt: Date(timeIntervalSince1970: 1), fingerprint: "image")
        repository.insert(image)
        let url = try require(repository.imageURL(for: image), "missing image URL")
        repository.insert(sample("replacement", 2))
        try expect(!FileManager.default.fileExists(atPath: url.path), "eviction leaked image")
        let pinned = sample("pinned", 3, pinned: true)
        repository.insert(pinned)
        repository.clearUnpinned()
        try expect(repository.items == [pinned], "clear unpinned did not preserve pin")
        repository.clearAll()
        try expect(repository.items.isEmpty, "clear all kept history")
    }

    private static func startup(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory, limit: 3)
        repository.insert(sample("old", 1))
        repository.insert(sample("new", 2))
        let name = try repository.storeImage(Data("orphan".utf8))
        let url = directory.appendingPathComponent("Images").appendingPathComponent(name)
        let reloaded = try HistoryRepository(directory: directory, limit: 1)
        try expect(reloaded.items.map(\.text) == ["new"], "startup limit not applied")
        try expect(!FileManager.default.fileExists(atPath: url.path), "startup orphan not removed")
        try expect(HistoryRepository(directory: directory).items == reloaded.items, "startup limit not persisted")
    }

    private static func corruption(_ directory: URL) throws {
        let initial = try HistoryRepository(directory: directory)
        let name = try initial.storeImage(Data("recoverable image".utf8))
        let data = Data("{\"items\": [broken".utf8)
        try data.write(to: directory.appendingPathComponent("history.json"))
        let recovered = try HistoryRepository(directory: directory)
        try expect(recovered.items.isEmpty && recovered.lastError != nil, "corruption not reported")
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backup = try require(contents.first { $0.lastPathComponent.hasPrefix("history.corrupt.") }, "missing corrupt metadata backup")
        try expect(Data(contentsOf: backup) == data, "corrupt data changed")
        let imageBackup = try require(contents.first { $0.lastPathComponent.hasPrefix("Images.corrupt.") }, "missing image backup")
        try expect(FileManager.default.fileExists(atPath: imageBackup.appendingPathComponent(name).path), "recoverable image removed")
        try expect(recovered.insert(sample("new beginning")), "recovered history not writable")
        try expect(HistoryRepository(directory: directory).items == recovered.items, "recovered history not persisted")
    }

    private static func futureFormat(_ directory: URL) throws {
        _ = try HistoryRepository(directory: directory)
        let data = try JSONEncoder().encode(HistoryArchive(version: 999, items: [sample("future")]))
        let url = directory.appendingPathComponent("history.json")
        try data.write(to: url)
        do {
            _ = try HistoryRepository(directory: directory)
            throw CheckFailure(description: "future archive version was accepted")
        } catch HistoryRepositoryError.unsupportedVersion(999) { }
        try expect(Data(contentsOf: url) == data, "future archive was modified")
    }

    private static func failedCommit(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory)
        let original = sample("original")
        repository.insert(original)
        let archive = directory.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        try expect(!repository.insert(sample("cannot persist", 200)), "failed commit reported success")
        try expect(repository.items == [original], "failed commit changed in-memory history")
        try expect(repository.lastError != nil, "failed write was not reported")
        try expect(FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }.isEmpty, "failed write leaked temporary file")
        try FileManager.default.removeItem(at: archive)
        try expect(repository.insert(sample("can persist", 300)), "write did not recover")
        try expect(repository.lastError == nil, "successful write did not reset error")
    }

    private static func safePaths(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory)
        for filename in ["../secret.png", "/etc/passwd", "..", ".", "", "dir\\image.png"] {
            let item = ClipboardItem(kind: .image, imageFile: filename, fingerprint: filename)
            try expect(repository.imageURL(for: item) == nil, "unsafe image path accepted: \(filename)")
        }
    }

    private static func titles(_ directory: URL) throws {
        try expect(sample("\n  Hello\nworld").title == "Hello", "multiline text title not trimmed")
        let files = ClipboardItem(kind: .files, filePaths: ["/tmp/one.png", "/tmp/two.png"], fingerprint: "files")
        try expect(files.title == "one.png 等 2 个文件", "multiple file title not summarized")
    }

    private static func metadataBudget(_ directory: URL) throws {
        let repository = try HistoryRepository(directory: directory)
        let payload = String(repeating: "x", count: 6 * 1024 * 1024)
        let pinned = ClipboardItem(kind: .text, text: payload, lastCopiedAt: Date(timeIntervalSince1970: 1), isPinned: true, fingerprint: "metadata-pin")
        let older = ClipboardItem(kind: .text, text: payload, lastCopiedAt: Date(timeIntervalSince1970: 2), fingerprint: "metadata-older")
        let recent = ClipboardItem(kind: .text, text: payload, lastCopiedAt: Date(timeIntervalSince1970: 3), fingerprint: "metadata-recent")
        for item in [pinned, older, recent] { repository.insert(item) }
        try expect(repository.items.map(\.id) == [pinned.id, recent.id], "text budget did not keep pin and latest fitting text")

        let paths = ClipboardItem(kind: .files, filePaths: [String(repeating: "p", count: 5 * 1024 * 1024)], lastCopiedAt: Date(timeIntervalSince1970: 4), fingerprint: "metadata-paths")
        repository.insert(paths)
        try expect(repository.items.map(\.id) == [pinned.id, paths.id], "file paths were not included in metadata budget")

        let oversizedPin = ClipboardItem(kind: .text, text: String(repeating: "z", count: 17 * 1024 * 1024), isPinned: true, fingerprint: "metadata-oversized-pin")
        repository.insert(oversizedPin)
        try expect(Set(repository.items.map(\.id)) == Set([pinned.id, oversizedPin.id]), "metadata budget removed a pin or kept unpinned text over budget")
        try expect(repository.items.allSatisfy(\.isPinned), "over-budget pinned metadata retained unpinned rows")
        try expect(repository.lastError == nil, "metadata budget caused a persistence error")
        try expect(HistoryRepository(directory: directory).items == repository.items, "over-budget pinned metadata was not preserved on reload")
    }

    private static func imageBudget(_ directory: URL) throws {
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
        try expect(repository.items.map(\.id) == [pinned.id, recent.id], "image budget did not evict the oldest unpinned blob")
        let olderURL = try require(repository.imageURL(for: older), "missing evicted image URL")
        try expect(!FileManager.default.fileExists(atPath: olderURL.path), "over-budget image blob was not reclaimed")

        let shared = image(firstName, time: 4)
        repository.insert(shared)
        try expect(repository.items.map(\.id) == [pinned.id, shared.id, recent.id], "shared image filename was counted more than once")
        try expect(HistoryRepository(directory: directory).items == repository.items, "loaded image size cache changed accepted items")

        repository.togglePin(id: recent.id)
        let extraName = try repository.storeImage(Data(repeating: 4, count: 30 * 1024 * 1024))
        let extraPin = image(extraName, time: 5, pinned: true)
        repository.insert(extraPin)
        try expect(Set(repository.items.map(\.id)) == Set([pinned.id, recent.id, extraPin.id]), "image budget removed a pin or kept unpinned blobs over budget")
        try expect(repository.items.allSatisfy(\.isPinned), "over-budget pinned images retained unpinned rows")
        try expect(repository.lastError == nil, "image budget caused a persistence error")
        try expect(HistoryRepository(directory: directory).items == repository.items, "over-budget pinned images were not preserved on reload")
    }
}
