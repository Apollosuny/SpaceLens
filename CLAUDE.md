# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                # Debug build
swift build -c release     # Release build
swift run SpaceLens        # Run the app
open Package.swift         # Open in Xcode
```

No external dependencies. No linter configured; Swift 6 strict concurrency mode is enforced via `swiftLanguageMode(.v6)` in Package.swift.

Tests use Swift Testing (`Tests/SpaceLensTests`, `@testable import SpaceLens`) with real temporary directory fixtures. Run one suite at a time, for example `swift test --filter IncrementalScannerTests`. `ScanBenchmarkTests` only runs when `SPACELENS_BENCHMARK_PATH` is set; it needs `-c release -Xswiftc -enable-testing`.

## Architecture

SpaceLens is a native macOS (15.0+) SwiftUI disk space analyzer that visualizes directory usage as interactive treemaps. Swift 6, SPM-only, zero external dependencies.

### State & Data Flow

**AppState** (`@Observable`) holds the current `screen` (welcome / scanning / results / failed), the last completed scan as a **ResultsModel**, sampled `scanProgress`, size metric and history. Results survive a new scan until it finishes, so cancelling returns to them. **ResultsModel** is the single source of truth for one scan: `viewRoot` (treemap folder), `selection`, sidebar `expandedFolders`, the `TreemapViewport` (zoom/pan) and a per-folder category breakdown cache; breadcrumbs are derived from `viewRoot`. Views read these per property, so keep hot values (progress, hover) out of views that render large subtrees.

Scan flow: User picks folder → **ScanCoordinator** (MainActor glue) runs **ScanEngine** in a detached task and samples `ScanProgress` (atomic counters) at 10 Hz → the engine tries an incremental update first: load the **ScanSnapshotStore** snapshot, replay the FSEvents journal from its checkpoint (**ChangeJournal**), and re-list only changed directories (**IncrementalScanner**). It falls back to a full walk (**FileScanner**) when there is no snapshot, the journal was reset, or too much changed → the tree is published, then the snapshot and history are persisted in the background.

### Module Layout (Sources/SpaceLens/)

- **App/** — Entry point (`SpaceLensApp`, owns `AppState` and `ScanCoordinator`), `AppState`, `ResultsModel`
- **Scanning/** — `DirectoryReader` (`getattrlistbulk` wrapper), `FileScanner` (parallel TaskGroup walk plus hard-link and clone de-duplication), `ScanScope` (mount and firmlink policy), `IncrementalScanner`, `ChangeJournal` (FSEvents history replay), `ScanEngine` (UI-independent pipeline), `ScanCoordinator`, `FileNode` (tree model with identity-based `id`/`Hashable` and weak parent refs; `finalizeTree()` computes aggregates)
- **Persistence/** — `SnapshotCodec` (varint pre-order encoding, LZ4), `ScanSnapshotStore` (Caches, 0600), `ScanHistoryStore` (Application Support JSON)
- **Categorization/** — `FileCategory` (10 categories with colors/SF Symbols) and `FileExtensionMap` (200+ extension→category mappings)
- **Treemap/** — `TreemapLayoutEngine` (Squarify algorithm; large folders get a header bar their children stay below, single-folder chains share one header, children under ~10×10 pt are grouped into one aggregate block; colors resolved per appearance by `TreemapPalette`: `ColorMode.folder` gives each top-level branch its own system hue, lighter by depth; `.kind` colors by `FileCategory`), `TreemapLayout` (pre-order items with subtree index for hit testing and node lookup), `TreemapRasterizer` (Core Graphics/Core Text bitmap, off the main actor), `TreemapViewport` (zoom/pan), `TreemapView` (shows the cached bitmap, stretched while a new one renders; hover/selection overlays, tooltip, context menu), `SunburstLayout`/`SunburstRasterizer`/`SunburstView` (4 rings around a center label, same palette and render pipeline; `AppState.chartStyle` picks treemap or sunburst)
- **Views/** — `ContentView` (NavigationSplitView: sidebar tree + detail + inspector, toolbar), `ResultsView` (breadcrumb, treemap or sunburst, legend per color mode), `WelcomeView` (volume list with usage rings, NSOpenPanel, folder drop), `ScanProgressView`, `DirectoryTreeView` (outline; row icons and share bars use the chart's colors via `SidebarColors`), `DetailPanelView` (grouped Form: metadata + category breakdown), `LiquidGlass` (glass helpers gated on macOS 26, material fallback on 15)
- **Utilities/** — `ByteFormatter` (human-readable sizes)

### Key Patterns

- All data types crossing async boundaries are `Sendable`
- FileNode uses weak parent references to break retain cycles
- Size semantics: `ownSize`/`totalSize` are logical; `allocatedSize`/`totalAllocatedSize` are physical as attributed. A hard-linked file is kept once. For a pure APFS clone family, only the first member seen is charged for the shared blocks
- Symlinks are never followed. Mount points are not crossed, except `/System/Volumes/Data` when scanning `/`, where firmlinked directories are skipped
- Published trees are immutable. Incremental scans mutate only a freshly decoded snapshot copy
- The treemap is laid out and rasterized off the main actor into one bitmap; the main thread only composites it. Never draw treemap or sunburst items in a SwiftUI `Canvas` per frame
- UI follows macOS HIG semantic colors plus Apple system colors for categories (light and dark); Liquid Glass only on the floating control layer (tooltip, action buttons), never on content
- macOS APIs used: `NSWorkspace` (Reveal in Finder), `NSPasteboard` (clipboard), `NSOpenPanel` (folder picker)
