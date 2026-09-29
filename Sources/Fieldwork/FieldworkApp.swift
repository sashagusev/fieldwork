import SwiftUI
import AppKit
import ResearchCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        // A plain white window, title bar included.
        DispatchQueue.main.async { for window in NSApp.windows { window.backgroundColor = .white; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct FieldworkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("Fieldwork", id: "workspace") {
            WorkspaceWindow().environmentObject(store).preferredColorScheme(.light)
                .frame(minWidth: 1050, minHeight: 650)
                .tint(Palette.accent)
        }
        .defaultSize(width: 1420, height: 940)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace…", action: store.newWorkspace).keyboardShortcut("n", modifiers: [.command,.shift])
                Button("Open Workspace…", action: store.chooseWorkspace).keyboardShortcut("o")
                Menu("Open Recent") {
                    if store.recentWorkspaces.isEmpty { Text("No Recent Workspaces") }
                    RecentWorkspacesMenu().environmentObject(store)
                }
                Divider()
                Button("New Question…") { store.newNode(.question) }.keyboardShortcut("n")
                Button("New Task…") { store.newNode(.task) }.keyboardShortcut("t", modifiers: [.command,.shift])
            }
            CommandMenu("Research") {
                Button("Aims") { store.show(.aims) }.keyboardShortcut("1")
                Button("Timeline") { store.show(.timeline) }.keyboardShortcut("2")
                Button("Graph") { store.show(.graph) }.keyboardShortcut("3")
                Button("Edit Selected…", action: store.editSelected).keyboardShortcut("e")
                Divider()
                Button("Undo Delete \(store.deletedHierarchy?.kind.label ?? "Item")", action: store.undoHierarchyDeletion).disabled(store.deletedHierarchy == nil)
                Button("Reload CSVs") { store.sync(force: true) }.keyboardShortcut("r")
                Toggle("Animated Transitions", isOn: $store.motion)
                Divider()
                Button("Open Example Workspace", action: store.openExample)
            }
        }
    }
}
