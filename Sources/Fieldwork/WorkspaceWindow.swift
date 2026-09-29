import SwiftUI
import ResearchCore

struct WorkspaceWindow: View {
    @EnvironmentObject var store: AppStore
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.diskError {
                HStack { Image(systemName: "exclamationmark.circle"); Text(error).font(.system(size: 11)); Spacer(); Button("Retry") { store.sync(force: true) } }.foregroundStyle(Palette.held).padding(8).background(Palette.held.opacity(0.06))
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 28)
                        if store.view == .timeline { ResearchTimeline().transition(.opacity) }
                        else if store.aims.isEmpty {
                            ContentUnavailableView { Label("Start with an aim", systemImage: "circle.dashed") } description: { Text("Aims hold questions; questions hold the steps that answer them.") } actions: { Button("Create Aim") { store.newNode(.aim) } }
                        } else if store.view == .graph { ResearchSpringGraph().transition(.opacity) }
                        else { ResearchLists().transition(.opacity) }
                    }.frame(width: (geometry.size.width - 1) * 0.6).frame(maxHeight: .infinity, alignment: .top)
                    Rectangle().fill(Palette.line).frame(width: 1)
                    ResearchInspector().frame(width: (geometry.size.width - 1) * 0.4)
                }
            }
        }
        .foregroundStyle(Palette.ink).background(Palette.card)
        .toolbarBackground(Palette.card, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            // The system title is hidden (see AppDelegate) so the workspace name and the views can sit together on the left.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Palette.ink).accessibilityHidden(true)
                    Text(store.repository?.url.lastPathComponent ?? "Fieldwork").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            // Flexible space keeps the views and menus together at the far right.
            ToolbarItem(placement: .principal) { Spacer() }
            ToolbarItemGroup(placement: .primaryAction) {
                HStack(spacing: 18) {
                    ForEach(WorkspaceView.allCases, id: \.self) { view in
                        Button(view.rawValue) { store.show(view) }
                            .buttonStyle(.plain).font(.system(size: 13, weight: store.view == view ? .medium : .regular))
                            .foregroundStyle(store.view == view ? Palette.ink : Palette.muted)
                            .accessibilityAddTraits(store.view == view ? .isSelected : [])
                    }
                }.padding(.trailing, 14)
                Menu {
                    Button("Open Workspace…", action: store.chooseWorkspace)
                    Button("New Workspace…", action: store.newWorkspace)
                    RecentWorkspacesMenu()
                } label: { Image(systemName: "folder") }.help("Open a workspace (⌘O)")
                Menu { ForEach(NodeKind.allCases) { kind in Button("New \(kind.label)") { store.newNode(kind) } } } label: { Image(systemName: "plus") }.help("Add research record")
            }
        }
        .animation(store.motion ? .easeInOut(duration: 0.2) : nil, value: store.view)
        .onReceive(timer) { _ in store.sync() }
        .sheet(item: $store.editor) { request in NodeEditor(request: request, workspace: store.workspace).id(request.id).environmentObject(store) }
        .sheet(item: $store.action) { request in WorkflowActionSheet(request: request).environmentObject(store) }
        .navigationTitle(store.repository?.url.lastPathComponent ?? "Fieldwork")
        .alert("Couldn’t save this change", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}

// Recently opened workspaces, most recent first; the open one is listed but ticked.
struct RecentWorkspacesMenu: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if !store.recentWorkspaces.isEmpty {
            Divider()
            ForEach(store.recentWorkspaces, id: \.path) { url in
                Button { store.open(url) } label: {
                    if store.repository?.url.path == url.path { Label(url.lastPathComponent, systemImage: "checkmark") } else { Text(url.lastPathComponent) }
                }.help(url.path)
            }
            Divider()
            Button("Clear Recent Workspaces", action: store.forgetRecentWorkspaces)
        }
    }
}
