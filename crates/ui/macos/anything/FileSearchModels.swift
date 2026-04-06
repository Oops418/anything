import SwiftUI
import Foundation
import GeneratedStore
import SwiftProtobuf

// MARK: - FileKind

enum FileKind: String, CaseIterable, Identifiable {
    case folder, image, doc, video, audio, code, archive, pdf

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .folder:  "📁"
        case .pdf:     "📄"
        case .image:   "🖼️"
        case .video:   "🎬"
        case .audio:   "🎵"
        case .code:    "💻"
        case .archive: "📦"
        case .doc:     "📝"
        }
    }

    var color: Color {
        switch self {
        case .folder:  Color(red: 56/255,  green: 145/255, blue: 255/255).opacity(0.75)
        case .image:   Color(red: 236/255, green: 72/255,  blue: 153/255).opacity(0.75)
        case .doc:     Color(red: 148/255, green: 163/255, blue: 184/255).opacity(0.75)
        case .video:   Color(red: 139/255, green: 92/255,  blue: 246/255).opacity(0.75)
        case .audio:   Color(red: 251/255, green: 146/255, blue: 60/255 ).opacity(0.75)
        case .code:    Color(red: 52/255,  green: 211/255, blue: 153/255).opacity(0.75)
        case .archive: Color(red: 251/255, green: 191/255, blue: 36/255 ).opacity(0.75)
        case .pdf:     Color(red: 239/255, green: 68/255,  blue: 68/255 ).opacity(0.75)
        }
    }
}

// MARK: - FileItem

struct FileItem: Identifiable, Hashable {
    let id: String
    let name: String
    let ext: String
    let path: String
    let size: String
    let modified: String
    let kind: FileKind
    let sizeBytes: Int64?
    let modifiedAt: Date?

    var displayName: String { ext.isEmpty ? name : "\(name).\(ext)" }
    var sortName: String { displayName.localizedLowercase }
    var sortPath: String { path.localizedLowercase }
    var sortSizeBytes: Int64 { sizeBytes ?? -1 }
    var sortModifiedAt: Date { modifiedAt ?? .distantPast }

    init(
        id: String,
        name: String,
        ext: String,
        path: String,
        size: String,
        modified: String,
        kind: FileKind,
        sizeBytes: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.ext = ext
        self.path = path
        self.size = size
        self.modified = modified
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }

    var emoji: String {
        let map: [String: String] = [
            "tsx": "⚛️", "ts": "⚛️", "js": "🟨", "json": "🗒️", "md": "📝",
            "swift": "🦅", "py": "🐍", "sql": "🗃️", "zip": "📦", "mp4": "🎬",
            "mov": "🎬", "mp3": "🎵", "m4a": "🎵", "png": "🖼️", "jpg": "🖼️",
            "jpeg": "🖼️", "heic": "🖼️", "pdf": "📄", "docx": "📝"
        ]
        return map[ext] ?? kind.emoji
    }

    var fileURL: URL {
        let expandedBasePath = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expandedBasePath).appendingPathComponent(displayName)
    }

    var previewURL: URL? {
        let candidateURL = fileURL
        if FileManager.default.fileExists(atPath: candidateURL.path) {
            return candidateURL
        }
        return PreviewPlaceholderStore.shared.previewURL(for: self)
    }
}

extension FileItem {
    /// Convenience single-item init — creates formatters each call.
    /// Use ``init(proto:sizeFormatter:dateFormatter:)`` when converting many items at once.
    init(proto file: Store_V1_FileInfo) {
        self.init(
            proto: file,
            sizeFormatter: Self.makeSizeFormatter(),
            dateFormatter: Self.makeDateFormatter()
        )
    }

    /// Batch init — pass pre-created formatters to amortise their initialisation cost
    /// across all items in a search result set.
    init(proto file: Store_V1_FileInfo, sizeFormatter: ByteCountFormatter, dateFormatter: DateFormatter) {
        let fullPath = NSString(string: file.path).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: fullPath)
        let fileExtension = fileURL.pathExtension.lowercased()
        let fileName = fileURL.lastPathComponent
        let baseName = fileExtension.isEmpty ? fileName : fileURL.deletingPathExtension().lastPathComponent
        let displayPath = fileURL.deletingLastPathComponent().path

        self.init(
            id: file.path.isEmpty ? "\(fileName)-\(file.size)" : file.path,
            name: baseName.isEmpty ? file.name : baseName,
            ext: fileExtension,
            path: displayPath,
            size: Self.formattedSize(file.size, using: sizeFormatter),
            modified: Self.formattedModified(file, using: dateFormatter),
            kind: .forFileExtension(fileExtension),
            sizeBytes: file.size,
            modifiedAt: Self.modifiedDate(file)
        )
    }

    static func makeSizeFormatter() -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }

    static func makeDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }

    private static func formattedSize(_ rawBytes: Int64, using formatter: ByteCountFormatter) -> String {
        guard rawBytes > 0 else { return "—" }
        return formatter.string(fromByteCount: rawBytes)
    }

    private static func formattedModified(_ file: Store_V1_FileInfo, using formatter: DateFormatter) -> String {
        guard let date = modifiedDate(file) else { return "—" }
        return formatter.string(from: date)
    }

    private static func modifiedDate(_ file: Store_V1_FileInfo) -> Date? {
        guard file.hasModified else { return nil }

        let timestamp = file.modified
        let seconds = TimeInterval(timestamp.seconds)
        let nanos = TimeInterval(timestamp.nanos) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds + nanos)
    }
}

private extension FileKind {
    static func forFileExtension(_ ext: String) -> Self {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg":
            .image
        case "mp4", "mov", "avi", "mkv", "webm":
            .video
        case "mp3", "m4a", "wav", "flac", "aac":
            .audio
        case "swift", "rs", "go", "py", "js", "ts", "tsx", "jsx", "json", "yml", "yaml", "toml", "sql", "sh", "rb", "kt", "java", "c", "cc", "cpp", "h", "hpp":
            .code
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z":
            .archive
        case "pdf":
            .pdf
        case "md", "txt", "rtf", "doc", "docx", "pages":
            .doc
        default:
            .doc
        }
    }
}

private final class PreviewPlaceholderStore {
    static let shared = PreviewPlaceholderStore()

    private let directoryURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("anything-preview-placeholders", isDirectory: true)

    func previewURL(for file: FileItem) -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let fileName = sanitizedFileName(for: file)
            let previewURL = directoryURL.appendingPathComponent(fileName)
            let contents = """
            \(file.displayName)

            Kind: \(file.kind.rawValue)
            Location: \(file.path)
            Size: \(file.size)
            Modified: \(file.modified)

            This is a generated preview placeholder because the source file is not available in the demo dataset.
            """

            try contents.write(to: previewURL, atomically: true, encoding: .utf8)
            return previewURL
        } catch {
            return nil
        }
    }

    private func sanitizedFileName(for file: FileItem) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        let safeBase = file.displayName.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        let baseName = String(safeBase).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let fallbackName = baseName.isEmpty ? "preview-item" : baseName
        return "\(fallbackName)-preview.txt"
    }
}

// MARK: - Mock Data

let mockFiles: [FileItem] = [
    .init(id: "1",  name: "ProjectProposal",    ext: "pdf",   path: "~/Documents/Work",          size: "2.4 MB",  modified: "Today, 10:32",  kind: .pdf),
    .init(id: "2",  name: "design-system",      ext: "",      path: "~/Desktop/Projects",         size: "—",       modified: "Today, 09:15",  kind: .folder),
    .init(id: "3",  name: "hero_image",         ext: "png",   path: "~/Downloads",                size: "4.1 MB",  modified: "Yesterday",     kind: .image),
    .init(id: "4",  name: "meeting-notes",      ext: "md",    path: "~/Documents/Notes",          size: "12 KB",   modified: "Yesterday",     kind: .doc),
    .init(id: "5",  name: "app",                ext: "tsx",   path: "~/Projects/liquid-ui/src",   size: "8.7 KB",  modified: "Mar 31",        kind: .code),
    .init(id: "6",  name: "screen-recording",   ext: "mov",   path: "~/Desktop",                  size: "312 MB",  modified: "Mar 30",        kind: .video),
    .init(id: "7",  name: "portfolio-backup",   ext: "zip",   path: "~/Documents/Archive",        size: "1.2 GB",  modified: "Mar 28",        kind: .archive),
    .init(id: "8",  name: "main",               ext: "swift", path: "~/Projects/AppKit/Sources",  size: "22 KB",   modified: "Mar 27",        kind: .code),
    .init(id: "9",  name: "ambient-track",      ext: "mp3",   path: "~/Music/Ambient",            size: "9.8 MB",  modified: "Mar 25",        kind: .audio),
    .init(id: "10", name: "invoice-2026-03",    ext: "pdf",   path: "~/Documents/Finance",        size: "340 KB",  modified: "Mar 24",        kind: .pdf),
    .init(id: "11", name: "screenshots",        ext: "",      path: "~/Desktop",                  size: "—",       modified: "Mar 23",        kind: .folder),
    .init(id: "12", name: "profile-photo",      ext: "jpg",   path: "~/Pictures",                 size: "1.7 MB",  modified: "Mar 20",        kind: .image),
    .init(id: "13", name: "README",             ext: "md",    path: "~/Projects/liquid-ui",       size: "3.2 KB",  modified: "Mar 19",        kind: .doc),
    .init(id: "14", name: "package",            ext: "json",  path: "~/Projects/liquid-ui",       size: "1.4 KB",  modified: "Mar 18",        kind: .code),
    .init(id: "15", name: "database-dump",      ext: "sql",   path: "~/Documents/Dev",            size: "56 MB",   modified: "Mar 15",        kind: .doc),
    .init(id: "16", name: "wallpaper-sonoma",   ext: "heic",  path: "~/Pictures/Wallpapers",      size: "7.3 MB",  modified: "Mar 12",        kind: .image),
    .init(id: "17", name: "podcast-episode-42", ext: "m4a",   path: "~/Music/Podcasts",           size: "48 MB",   modified: "Mar 10",        kind: .audio),
    .init(id: "18", name: "components",         ext: "",      path: "~/Projects/liquid-ui/src",   size: "—",       modified: "Mar 9",         kind: .folder),
    .init(id: "19", name: "WWDC-keynote",       ext: "mp4",   path: "~/Movies",                   size: "2.1 GB",  modified: "Mar 8",         kind: .video),
    .init(id: "20", name: "resume-2026",        ext: "pdf",   path: "~/Documents",                size: "180 KB",  modified: "Mar 5",         kind: .pdf),
    .init(id: "21", name: "tailwind.config",    ext: "js",    path: "~/Projects/liquid-ui",       size: "860 B",   modified: "Mar 4",         kind: .code),
    .init(id: "22", name: "design-tokens",      ext: "json",  path: "~/Projects/design-system",   size: "14 KB",   modified: "Mar 3",         kind: .code),
    .init(id: "23", name: "book-draft",         ext: "docx",  path: "~/Documents/Writing",        size: "245 KB",  modified: "Mar 1",         kind: .doc),
    .init(id: "24", name: "node_modules",       ext: "",      path: "~/Projects/liquid-ui",       size: "—",       modified: "Feb 28",        kind: .folder),
]

// MARK: - Search

func queryFiles(_ query: String) -> [FileItem] {
    let q = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    return mockFiles.filter {
        $0.name.lowercased().contains(q) ||
        $0.ext.lowercased().contains(q) ||
        $0.path.lowercased().contains(q)
    }
}
