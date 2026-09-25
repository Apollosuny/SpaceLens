# SpaceLens

**Free, open-source disk space analyzer for macOS — like [WinDirStat](https://windirstat.net/), but native to the Mac.**

Find out what's eating your storage with interactive treemap visualizations, just like WinDirStat and WizTree on Windows. SpaceLens is a fast, lightweight, native macOS app built with SwiftUI — no Electron, no subscriptions, no tracking.

![SpaceLens — free macOS disk space analyzer with treemap visualization](screenshot.png)

## Why SpaceLens?

- **Free and open source** — no paywall, no trial limits, no ads
- **Native macOS app** — built with SwiftUI, feels right at home on your Mac
- **Fast scanning** — parallel traversal with `getattrlistbulk`, about 2.5× faster than `du` on a warm cache
- **Fast rescans** — reuses the previous result and re-reads only folders changed since then (via the FSEvents journal)
- **Zero dependencies** — nothing to install, no runtimes, no frameworks to download
- **Privacy-first** — runs entirely offline, never phones home

If you've used **WinDirStat**, **WizTree**, or **TreeSize** on Windows and want the same experience on macOS, SpaceLens is the answer. It's also a great free alternative to **DaisyDisk**, **GrandPerspective**, and **OmniDiskSweeper**.

## Features

- **Interactive Treemap Visualization** — Squarify algorithm renders directories and files as proportionally-sized, color-coded rectangles
- **Directory Tree Sidebar** — Hierarchical outline view for browsing the file tree alongside the treemap
- **File Inspector** — Detail panel showing file size, allocated size, file/directory counts, modification dates, and a category breakdown chart
- **Breadcrumb Navigation** — Drill down into subdirectories and navigate back via breadcrumb bar
- **10 File Categories** — Documents, Images, Video, Audio, Code, Archives, Applications, System, Caches, and Other — each with distinct colors
- **Logical vs Physical Size** — Switch between logical size and real on-disk usage. Sparse files report the blocks they actually use, hard links count once, and pure APFS clones charge their shared blocks once
- **Whole-Disk Scans** — Scanning the startup disk covers the Data volume through its firmlinks without double counting, and never crosses into other mounts or network shares
- **Scan History** — Recent scans on the launch screen; rescanning one reuses its cached result
- **Skipped Folder Report** — Folders macOS won't let SpaceLens read are listed, with a shortcut to grant Full Disk Access
- **Hidden Files** — Included by default (they still use space), with an option to exclude them
- **Volume Picker** — Launch screen shows mounted drives with usage bars, or scan any custom folder
- **Zoom & Pan** — Scroll to zoom into dense treemap regions
- **Reveal in Finder** — Jump to any file or folder directly from the inspector
- **Copy Path** — One-click path copying to clipboard

## Installation

### Build from source

Requires macOS 15.0+ and Swift 6.

```bash
git clone https://github.com/phalladar/MacDirStat.git
cd macdirstat
swift build -c release
swift run SpaceLens
```

Or open in Xcode:

```bash
open Package.swift
```

Zero external dependencies. Pure Swift Package Manager project.

### Tests

```bash
swift test --filter FileScannerTests        # run one suite
SPACELENS_BENCHMARK_PATH=~/Library swift test -c release -Xswiftc -enable-testing --filter ScanBenchmarkTests
```

## Architecture

SpaceLens is built with SwiftUI and Swift 6 strict concurrency. A single `@Observable` **AppState** drives all views.

**Scan pipeline:** User picks a folder → **ScanCoordinator** runs **ScanEngine** off the main actor → the engine either loads the cached snapshot and replays the FSEvents journal to update only changed folders (**IncrementalScanner**), or walks the whole tree (**FileScanner**, parallel `getattrlistbulk` traversal) → workers update lock-free progress counters that the coordinator samples at 10 Hz → the finished tree is published and saved as a snapshot in the background.

### Project Structure

```
Sources/SpaceLens/
├── App/              # Entry point, AppState
├── Scanning/         # FileScanner, IncrementalScanner, ChangeJournal (FSEvents), ScanEngine, FileNode
├── Persistence/      # Snapshot cache (binary, LZ4) and scan history
├── Categorization/   # FileCategory definitions, 200+ extension mappings
├── Treemap/          # Squarify layout engine, Canvas renderer, hit testing
├── Views/            # ContentView, WelcomeView, DirectoryTreeView, DetailPanelView
└── Utilities/        # ByteFormatter
```

## Contributing

Contributions are welcome! Open an issue or submit a pull request.

## Related Projects

- [WinDirStat](https://windirstat.net/) — the original Windows disk usage analyzer
- [WizTree](https://diskanalyzer.com/) — fast disk space analyzer for Windows
- [GrandPerspective](https://grandperspectiv.sourceforge.net/) — treemap disk visualizer for macOS
- [DaisyDisk](https://daisydiskapp.com/) — commercial macOS disk analyzer
