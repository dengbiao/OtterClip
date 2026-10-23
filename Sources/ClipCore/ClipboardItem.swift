import Foundation

public enum ClipKind: String, Codable, CaseIterable {
    case text
    case image
    case files
}

/// One locally stored clipboard value. Image bytes live separately in the repository.
public struct ClipboardItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var kind: ClipKind
    public var text: String
    public var imageFile: String?
    public var filePaths: [String]
    public var sourceApp: String
    public var sourceBundleID: String?
    public var createdAt: Date
    public var lastCopiedAt: Date
    public var copyCount: Int
    public var isPinned: Bool
    public var fingerprint: String

    public init(
        id: UUID = UUID(),
        kind: ClipKind,
        text: String = "",
        imageFile: String? = nil,
        filePaths: [String] = [],
        sourceApp: String = "",
        sourceBundleID: String? = nil,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        copyCount: Int = 1,
        isPinned: Bool = false,
        fingerprint: String
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFile = imageFile
        self.filePaths = filePaths
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.isPinned = isPinned
        self.fingerprint = fingerprint
    }

    public var title: String {
        switch kind {
        case .text:
            let firstLine = text.components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "空白文本"
            return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(160))
        case .image:
            return text.isEmpty ? "图片" : String(text.prefix(160))
        case .files:
            guard let path = filePaths.first else { return "文件" }
            let name = URL(fileURLWithPath: path).lastPathComponent
            return filePaths.count == 1 ? name : "\(name) 等 \(filePaths.count) 个文件"
        }
    }

    public var searchableText: String {
        ([title, text, sourceApp, sourceBundleID ?? ""] + filePaths).joined(separator: "\n")
    }
}

public enum HistoryFilter: String, CaseIterable {
    case all
    case text
    case images
    case files
    case pinned
}

public struct HistoryArchive: Codable {
    public var version: Int
    public var items: [ClipboardItem]

    public init(version: Int = 1, items: [ClipboardItem] = []) {
        self.version = version
        self.items = items
    }
}
