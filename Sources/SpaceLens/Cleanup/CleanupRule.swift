import SwiftUI

/// How safe it is to remove what a rule matches.
enum CleanupRisk: Int, CaseIterable, Comparable, Sendable {
    /// Rebuilt or downloaded again on demand; removing it loses nothing.
    case safe
    /// Often unneeded, but only the user can tell.
    case review
    /// Owned by macOS, apps or the user; SpaceLens never suggests removing it.
    case protected

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .safe: "Safe to Clean"
        case .review: "Review First"
        case .protected: "Do Not Touch"
        }
    }

    var shortTitle: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .protected: "Keep"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .protected: .red
        }
    }

    var sfSymbol: String {
        switch self {
        case .safe: "checkmark.seal.fill"
        case .review: "exclamationmark.triangle.fill"
        case .protected: "lock.fill"
        }
    }
}

/// What happens to the data after it is removed.
enum CleanupRecovery: Sendable {
    /// The owning tool recreates it when needed.
    case regenerated
    /// Downloaded again from its source when needed.
    case redownloaded
    /// Gone for good once the Trash is emptied.
    case notRecoverable

    var summary: String {
        switch self {
        case .regenerated: "Rebuilt automatically when needed"
        case .redownloaded: "Downloaded again when needed"
        case .notRecoverable: "Can't be recovered once the Trash is emptied"
        }
    }
}

/// File-level criteria for rules that match wherever files turn up (disk images, archives, videos…).
struct CleanupFilePattern: Sendable {
    /// Lowercased extensions without the dot. Empty means any extension.
    var extensions: Set<String> = []
    var category: FileCategory?
    var minSize: Int64 = 0
}

/// Where a rule applies. Paths are absolute; `CleanupRuleset.default(home:)` expands the home folder.
enum CleanupMatcher: Sendable {
    /// The folder or file at this path, as one item.
    case item(String)
    /// Each entry directly inside this folder, as its own item, optionally only those unmodified for
    /// `minAgeDays`. The folder itself is shown as the container of those items.
    case contents(of: String, minAgeDays: Int? = nil)
    /// Every file matching the pattern outside protected areas, packages and other rules' items.
    case files(CleanupFilePattern)
}

/// One piece of cleanup knowledge: what it matches, how risky removing it is and why.
struct CleanupRule: Identifiable, Sendable {
    let id: String
    let title: String
    let risk: CleanupRisk
    let recovery: CleanupRecovery
    /// One sentence on what the data is and what removing it costs.
    let explanation: String
    let matchers: [CleanupMatcher]
}

/// The rules SpaceLens applies to a scan, in precedence order for file patterns (first match wins).
/// Path rules take precedence by specificity instead: the deepest path claims its subtree.
struct CleanupRuleset: Sendable {
    let rules: [CleanupRule]
    /// Folder extensions treated as opaque packages: file patterns never look inside them, since their
    /// contents belong to the app or library that owns them.
    let packageExtensions: Set<String>

    static func `default`(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> CleanupRuleset {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        func inHome(_ relative: String) -> String { "\(home)/\(relative)" }

        let rules: [CleanupRule] = [
            // Safe to clean
            CleanupRule(
                id: "xcode-derived-data", title: "Xcode DerivedData", risk: .safe, recovery: .regenerated,
                explanation: "Build products and indexes. Xcode regenerates them the next time you build.",
                matchers: [.item(inHome("Library/Developer/Xcode/DerivedData"))]
            ),
            CleanupRule(
                id: "xcode-device-support", title: "Xcode Device Support", risk: .safe, recovery: .regenerated,
                explanation: "Debug symbols copied from devices. Xcode copies them again when you connect a device.",
                matchers: ["iOS", "watchOS", "tvOS", "visionOS"].map { .contents(of: inHome("Library/Developer/Xcode/\($0) DeviceSupport")) }
            ),
            CleanupRule(
                id: "simulator-caches", title: "Simulator Caches", risk: .safe, recovery: .regenerated,
                explanation: "Caches of the iOS Simulator runtimes. They are rebuilt when a simulator boots.",
                matchers: [.item(inHome("Library/Developer/CoreSimulator/Caches"))]
            ),
            CleanupRule(
                id: "homebrew-cache", title: "Homebrew Cache", risk: .safe, recovery: .redownloaded,
                explanation: "Downloaded bottles and source archives. Homebrew fetches them again if a reinstall needs them.",
                matchers: [.item(inHome("Library/Caches/Homebrew"))]
            ),
            CleanupRule(
                id: "npm-cache", title: "npm Cache", risk: .safe, recovery: .redownloaded,
                explanation: "Packages npm downloaded before. npm downloads them again on the next install that needs them.",
                matchers: [.item(inHome(".npm/_cacache"))]
            ),
            CleanupRule(
                id: "pnpm-store", title: "pnpm Store", risk: .safe, recovery: .redownloaded,
                explanation: "Shared package store. Installed projects keep working; pnpm downloads packages again on the next install.",
                matchers: [
                    .item(inHome("Library/pnpm/store")),
                    .item(inHome(".local/share/pnpm/store")),
                    .item(inHome(".pnpm-store"))
                ]
            ),
            CleanupRule(
                id: "gradle-cache", title: "Gradle Caches", risk: .safe, recovery: .redownloaded,
                explanation: "Downloaded dependencies and build caches. Gradle fetches them again on the next build.",
                matchers: [.item(inHome(".gradle/caches"))]
            ),
            CleanupRule(
                id: "user-caches", title: "App Caches", risk: .safe, recovery: .regenerated,
                explanation: "Data apps keep to load faster. Apps rebuild their caches; quit an app before clearing its cache.",
                matchers: [.contents(of: inHome("Library/Caches"))]
            ),
            CleanupRule(
                id: "user-logs", title: "Logs", risk: .safe, recovery: .notRecoverable,
                explanation: "Diagnostic logs. Apps start new ones; you only lose past history.",
                matchers: [.contents(of: inHome("Library/Logs"))]
            ),

            // Review first
            CleanupRule(
                id: "old-downloads", title: "Old Downloads", risk: .review, recovery: .notRecoverable,
                explanation: "Downloads not changed in over 90 days. Check them first: they may not be available to download again.",
                matchers: [.contents(of: inHome("Downloads"), minAgeDays: 90)]
            ),
            CleanupRule(
                id: "ios-backups", title: "iPhone & iPad Backups", risk: .review, recovery: .notRecoverable,
                explanation: "Device backups made by Finder. Keep the latest backup of any device you still use.",
                matchers: [.contents(of: inHome("Library/Application Support/MobileSync/Backup"))]
            ),
            CleanupRule(
                id: "xcode-archives", title: "Xcode Archives", risk: .review, recovery: .notRecoverable,
                explanation: "Needed to symbolicate crash reports of shipped builds. Keep the archives of releases you still support.",
                matchers: [.contents(of: inHome("Library/Developer/Xcode/Archives"))]
            ),
            CleanupRule(
                id: "simulator-devices", title: "Simulator Devices", risk: .review, recovery: .notRecoverable,
                explanation: "Simulators and the apps and data installed in them. Running “xcrun simctl delete unavailable” removes only those of runtimes you no longer have.",
                matchers: [.item(inHome("Library/Developer/CoreSimulator/Devices"))]
            ),
            CleanupRule(
                id: "trash", title: "Trash", risk: .review, recovery: .notRecoverable,
                explanation: "Items you already deleted. Emptying the Trash removes them for good.",
                matchers: [.item(inHome(".Trash"))]
            ),
            CleanupRule(
                id: "disk-images", title: "Disk Images", risk: .review, recovery: .redownloaded,
                explanation: "Installer images are rarely needed after the app is installed, and can usually be downloaded again.",
                matchers: [.files(CleanupFilePattern(extensions: ["dmg", "iso"]))]
            ),
            CleanupRule(
                id: "archives", title: "Large Archives", risk: .review, recovery: .notRecoverable,
                explanation: "Compressed copies over 50 MB. Remove them once their contents are extracted or backed up elsewhere.",
                matchers: [.files(CleanupFilePattern(extensions: ["zip", "xip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z"], minSize: 50_000_000))]
            ),
            CleanupRule(
                id: "large-videos", title: "Large Videos", risk: .review, recovery: .notRecoverable,
                explanation: "Videos over 1 GB. Move the ones you want to keep to external storage.",
                matchers: [.files(CleanupFilePattern(category: .video, minSize: 1_000_000_000))]
            ),

            // Do not touch
            CleanupRule(
                id: "macos-system", title: "macOS System", risk: .protected, recovery: .notRecoverable,
                explanation: "Managed by macOS. Removing any of it can stop the Mac from working.",
                matchers: ["/System", "/usr", "/bin", "/sbin", "/private"].map { .item($0) }
            ),
            CleanupRule(
                id: "shared-library", title: "Shared App Data", risk: .protected, recovery: .notRecoverable,
                explanation: "Support files installed for all users. Remove them only through the app that installed them.",
                matchers: [.item("/Library")]
            ),
            CleanupRule(
                id: "applications", title: "Applications", risk: .protected, recovery: .notRecoverable,
                explanation: "Installed apps. Uninstall an app as a whole instead of removing parts of it.",
                matchers: [.item("/Applications")]
            ),
            CleanupRule(
                id: "app-data", title: "App Data & Settings", risk: .protected, recovery: .notRecoverable,
                explanation: "Settings and data of installed apps. Remove an app's data only after uninstalling the app.",
                matchers: ["Application Support", "Containers", "Group Containers", "Preferences", "Keychains"]
                    .map { .item(inHome("Library/\($0)")) }
            ),
            CleanupRule(
                id: "mail-messages", title: "Mail & Messages", risk: .protected, recovery: .notRecoverable,
                explanation: "Your mail and message history. Manage it inside Mail and Messages.",
                matchers: [.item(inHome("Library/Mail")), .item(inHome("Library/Messages"))]
            ),
            CleanupRule(
                id: "icloud-drive", title: "iCloud Drive", risk: .protected, recovery: .notRecoverable,
                explanation: "Synced with iCloud: deleting a file here deletes it on all your devices.",
                matchers: [.item(inHome("Library/Mobile Documents"))]
            ),
            CleanupRule(
                id: "user-documents", title: "Your Documents", risk: .protected, recovery: .notRecoverable,
                explanation: "Your personal files. SpaceLens never suggests removing them.",
                matchers: ["Documents", "Desktop", "Pictures"].map { .item(inHome($0)) }
            )
        ]

        return CleanupRuleset(
            rules: rules,
            packageExtensions: [
                "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "photoslibrary", "musiclibrary",
                "tvlibrary", "photolibrary", "imovielibrary", "fcpbundle", "logicx", "xcarchive", "xcodeproj",
                "xcworkspace", "playground", "sparsebundle"
            ]
        )
    }
}
