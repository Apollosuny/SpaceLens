import SwiftUI

enum FileCategory: String, CaseIterable, Sendable, Identifiable {
    case documents
    case images
    case video
    case audio
    case code
    case archives
    case applications
    case system
    case caches
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .documents: "Documents"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .code: "Code"
        case .archives: "Archives"
        case .applications: "Applications"
        case .system: "System"
        case .caches: "Caches"
        case .other: "Other"
        }
    }

    /// Apple system colors, which adapt to light and dark appearance. Resolve them with the view's
    /// environment (`Color.resolve(in:)`) when drawing outside the view hierarchy.
    var color: Color {
        switch self {
        case .documents: .blue
        case .images: .green
        case .video: .red
        case .audio: .orange
        case .code: .purple
        case .archives: .cyan
        case .applications: .pink
        case .system: .teal
        case .caches: .brown
        // Most bytes in bundles and libraries are "other"; a neutral gray keeps the map calm and lets
        // recognized types stand out.
        case .other: .gray
        }
    }

    var sfSymbol: String {
        switch self {
        case .documents: "doc.text.fill"
        case .images: "photo.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archives: "archivebox.fill"
        case .applications: "app.fill"
        case .system: "gearshape.fill"
        case .caches: "cylinder.fill"
        case .other: "questionmark.folder.fill"
        }
    }
}
