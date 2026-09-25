import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM executable (no .app bundle) launches in the background, leaving its window behind Xcode or Terminal.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SpaceLensApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var appState: AppState
    @State private var coordinator: ScanCoordinator
    @AppStorage("includeHiddenFiles") private var includeHiddenFiles = true

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        _coordinator = State(initialValue: ScanCoordinator(appState: appState))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder…") {
                    guard let path = FolderPicker.chooseFolder() else { return }
                    coordinator.startScan(path: path, options: ScanOptions(includeHiddenFiles: includeHiddenFiles))
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
