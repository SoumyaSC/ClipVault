import Foundation

/// A single captured clipboard entry.
struct ClipItem: Identifiable, Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case text
        case image
        case files
    }

    let id: UUID
    var kind: Kind
    /// Creation time (bumped to "now" when the same content is re-copied).
    var createdAt: Date
    var pinned: Bool
    var pinnedAt: Date?
    /// True when the source marked the copy as concealed (password managers) and
    /// capture of concealed data was allowed by the user.
    var sensitive: Bool
    /// SHA-256 hex of the canonical payload; used for deduplication.
    var contentHash: String
    /// Short plain-text preview used for the list and search (text kind only).
    var textPreview: String?
    var characterCount: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// Payload size in bytes (text bytes, PNG bytes; 0 for files kind).
    var byteSize: Int
    /// Absolute paths for the `files` kind.
    var filePaths: [String]?
    /// True when HTML and/or RTF sidecars exist for faithful rich-text restore.
    var hasRichText: Bool

    init(id: UUID = UUID(),
         kind: Kind,
         createdAt: Date = Date(),
         pinned: Bool = false,
         pinnedAt: Date? = nil,
         sensitive: Bool = false,
         contentHash: String,
         textPreview: String? = nil,
         characterCount: Int? = nil,
         pixelWidth: Int? = nil,
         pixelHeight: Int? = nil,
         byteSize: Int = 0,
         filePaths: [String]? = nil,
         hasRichText: Bool = false) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.pinned = pinned
        self.pinnedAt = pinnedAt
        self.sensitive = sensitive
        self.contentHash = contentHash
        self.textPreview = textPreview
        self.characterCount = characterCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteSize = byteSize
        self.filePaths = filePaths
        self.hasRichText = hasRichText
    }

    // MARK: - Manifest container

    struct Manifest: Codable {
        var version: Int = 1
        var items: [ClipItem]
    }
}
