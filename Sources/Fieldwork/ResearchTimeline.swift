import SwiftUI
import ResearchCore

struct ResearchTimeline: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let nodes = store.timelineNodes
        if nodes.isEmpty {
            ContentUnavailableView {
                Label("Nothing yet", systemImage: "clock")
            } description: {
                Text("Your newest records appear at the top.")
            } actions: {
                Button("Create Aim") { store.newNode(.aim) }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(nodes) { node in
                        HStack(alignment: .center, spacing: 12) {
                            Group {
                                if let created = parseTimestamp(node.createdAt) { Text(created, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                                else { Text("") }
                            }
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
                            .frame(width: 96, alignment: .leading)
                            FlatRow(node: node)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 24 + RowMetrics.padding).padding(.trailing, 24).padding(.bottom, 40)
            }.scrollIndicators(.never)
        }
    }
}

// A row outside its hierarchy: clicking selects it, double-clicking shows it among the aims.
struct FlatRow: View {
    @EnvironmentObject var store: AppStore
    var node: ResearchNode
    var body: some View {
        ListRow(node: node, caption: node.kind.label, flat: true, reportsFrame: false) { store.select(node) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { store.reveal(node) })
            .help("Double-click to show in Aims")
    }
}
