import CryptoKit
import Darwin
import Foundation

public enum HistoryRepositoryError: LocalizedError {
    case unsupportedVersion(Int)
    case recoveredCorruptArchive(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "历史文件版本 \(version) 比当前应用更新，无法读取。原文件已保留。"
        case .recoveredCorruptArchive(let url):
            return "历史文件损坏，已保留到 \(url.lastPathComponent)，并开始新的历史记录。"
        }
    }
}

/// Main-thread repository. Mutations are committed to disk before `items` changes.
/// A failed mutation leaves the previous history intact and exposes `lastError`.
public final class HistoryRepository {
    public private(set) var items: [ClipboardItem] = []
    public private(set) var lastError: Error?

    private let directory: URL
    private let imagesDirectory: URL
    private let archiveURL: URL
    private let fileManager = FileManager.default
    private var limit: Int
    private var imageSizes: [String: Int] = [:]
    private static let metadataBudget = 16 * 1024 * 1024
    private static let imagesBudget = 100 * 1024 * 1024

    public init(directory: URL, limit: Int = 300) throws {
        self.directory = directory.standardizedFileURL
        self.imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        self.archiveURL = directory.appendingPathComponent("history.json")
        self.limit = max(0, limit)
        try prepareDirectory(self.directory)
        try prepareDirectory(imagesDirectory)
        imageSizes = try loadImageSizes()

        guard fileManager.fileExists(atPath: archiveURL.path) else { return }
        // A read/permission failure must not be mistaken for corrupt JSON.
        let data = try Data(contentsOf: archiveURL)
        let archive: HistoryArchive
        do {
            archive = try JSONDecoder().decode(HistoryArchive.self, from: data)
        } catch {
            let recoveryID = UUID().uuidString
            let backup = self.directory.appendingPathComponent("history.corrupt.\(recoveryID).json")
            try fileManager.moveItem(at: archiveURL, to: backup)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            // Keep image blobs recoverable alongside the damaged metadata.
            if !(try fileManager.contentsOfDirectory(atPath: imagesDirectory.path)).isEmpty {
                let recoveredImages = self.directory.appendingPathComponent("Images.corrupt.\(recoveryID)")
                try fileManager.moveItem(at: imagesDirectory, to: recoveredImages)
                try prepareDirectory(imagesDirectory)
            }
            imageSizes = [:]
            lastError = HistoryRepositoryError.recoveredCorruptArchive(backup)
            return
        }
        guard archive.version == 1 else {
            throw HistoryRepositoryError.unsupportedVersion(archive.version)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        let normalized = normalize(archive.items)
        items = normalized
        // Apply a changed limit on startup, including persisted removal and blob reclamation.
        if normalized != archive.items {
            try writeArchive(normalized)
        }
        try removeUnreferencedImages(referencedBy: normalized)
    }

    /// Returns true for a newly accepted value; duplicates update their original entry.
    @discardableResult
    public func insert(_ item: ClipboardItem) -> Bool {
        var updated = items
        let isNew: Bool
        if let index = updated.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            var existing = updated.remove(at: index)
            existing.lastCopiedAt = item.lastCopiedAt
            existing.copyCount = existing.copyCount == Int.max ? Int.max : max(0, existing.copyCount) + 1
            existing.sourceApp = item.sourceApp
            existing.sourceBundleID = item.sourceBundleID
            updated.append(existing)
            isNew = false
        } else {
            var accepted = item
            accepted.copyCount = max(1, accepted.copyCount)
            updated.append(accepted)
            isNew = true
        }
        return commit(updated) && isNew
    }

    public func togglePin(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        updated[index].isPinned.toggle()
        commit(updated)
    }

    public func remove(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        commit(items.filter { $0.id != id })
    }

    public func clearUnpinned() {
        commit(items.filter(\.isPinned))
    }

    public func clearAll() {
        commit([])
    }

    public func setLimit(_ limit: Int) {
        let oldLimit = self.limit
        self.limit = max(0, limit)
        if !commit(items) { self.limit = oldLimit }
    }

    public func search(query: String, filter: HistoryFilter = .all) -> [ClipboardItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .text: matchesFilter = item.kind == .text
            case .images: matchesFilter = item.kind == .image
            case .files: matchesFilter = item.kind == .files
            case .pinned: matchesFilter = item.isPinned
            }
            guard matchesFilter else { return false }
            let searchableText = item.searchableText
            return words.allSatisfy {
                searchableText.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    public func imageURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFile,
              !name.isEmpty, name != ".", name != "..",
              name == (name as NSString).lastPathComponent,
              !name.contains("\\") else { return nil }
        return imagesDirectory.appendingPathComponent(name)
    }

    @discardableResult
    public func storeImage(_ data: Data) throws -> String {
        do {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let filename = "\(hash).png"
            let url = imagesDirectory.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: url.path) {
                try writeAtomically(data, to: url)
                imageSizes[filename] = data.count
            } else {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                imageSizes[filename] = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }
            lastError = nil
            return filename
        } catch {
            lastError = error
            throw error
        }
    }

    @discardableResult
    private func commit(_ proposedItems: [ClipboardItem]) -> Bool {
        let updated = normalize(proposedItems)
        do {
            try writeArchive(updated)
        } catch {
            lastError = error
            return false
        }
        items = updated
        lastError = nil
        do {
            try removeUnreferencedImages(referencedBy: updated)
        } catch {
            // Metadata is already committed. Surface cleanup errors without undoing it.
            lastError = error
        }
        return true
    }

    private func normalize(_ proposedItems: [ClipboardItem]) -> [ClipboardItem] {
        let sorted = proposedItems.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.lastCopiedAt != $1.lastCopiedAt { return $0.lastCopiedAt > $1.lastCopiedAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var seen = Set<String>()
        var unpinnedCount = 0
        var metadataBytes = 0
        var imageBytes = 0
        var countedImages = Set<String>()
        return sorted.filter { item in
            guard seen.insert(item.fingerprint).inserted else { return false }
            let itemMetadataBytes = item.text.utf8.count + item.filePaths.reduce(512) { $0 + $1.utf8.count }
            let newImage = item.imageFile.flatMap { countedImages.contains($0) ? nil : $0 }
            let itemImageBytes = newImage.map { cachedImageSize(named: $0) } ?? 0
            if !item.isPinned {
                // Pins are accounted for first and may exceed either budget themselves.
                guard unpinnedCount < limit,
                      metadataBytes <= Self.metadataBudget,
                      itemMetadataBytes <= Self.metadataBudget - metadataBytes,
                      imageBytes <= Self.imagesBudget,
                      itemImageBytes <= Self.imagesBudget - imageBytes else { return false }
                unpinnedCount += 1
            }
            metadataBytes += itemMetadataBytes
            imageBytes += itemImageBytes
            if let newImage { countedImages.insert(newImage) }
            return true
        }
    }

    private func loadImageSizes() throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        for url in try fileManager.contentsOfDirectory(
            at: imagesDirectory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { sizes[url.lastPathComponent] = values.fileSize ?? 0 }
        }
        return sizes
    }

    private func cachedImageSize(named filename: String) -> Int {
        if let size = imageSizes[filename] { return size }
        guard !filename.isEmpty, filename != ".", filename != "..",
              filename == (filename as NSString).lastPathComponent,
              !filename.contains("\\") else { return 0 }
        let url = imagesDirectory.appendingPathComponent(filename)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        imageSizes[filename] = size
        return size
    }

    private func prepareDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeArchive(_ items: [ClipboardItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(HistoryArchive(items: items))
        try writeAtomically(data, to: archiveURL)
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        defer { try? fileManager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let status = temporary.withUnsafeFileSystemRepresentation { temporaryPath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                Darwin.rename(temporaryPath!, destinationPath!)
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeUnreferencedImages(referencedBy items: [ClipboardItem]) throws {
        let referencedNames = Set(items.compactMap(\.imageFile))
        for url in try fileManager.contentsOfDirectory(
            at: imagesDirectory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            guard !referencedNames.contains(url.lastPathComponent),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try fileManager.removeItem(at: url)
            imageSizes.removeValue(forKey: url.lastPathComponent)
        }
    }
}
