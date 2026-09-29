import SwiftUI
import Foundation

// Foundation parses Markdown; presentation intents supply its block structure.
// SwiftUI renders text directly, so embedded HTML never executes.
struct MarkdownBlock: Identifiable {
    enum Kind { case paragraph, heading(Int), code(String?), rule }
    let id: Int
    var text: AttributedString
    var kind: Kind = .paragraph
    var listDepth = 0
    var quoteDepth = 0
    var marker: String?
    var tableID: Int?
    var rowID: Int?
    var tableHeader = false
    var alignment: Alignment = .leading

    static func parse(_ source: String) -> [MarkdownBlock] {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return [MarkdownBlock(id: 0, text: AttributedString(source))]
        }
        var blocks: [MarkdownBlock] = []
        var markedItems: Set<Int> = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if run.inlinePresentationIntent?.contains(.code) == true {
                text.font = .system(size: 12, design: .monospaced)
                text.backgroundColor = Palette.quiet
            }
            if blocks.last?.id == id {
                blocks[blocks.count - 1].text.append(text)
                continue
            }
            var block = MarkdownBlock(id: id, text: text)
            var listItem: (id: Int, ordinal: Int)?
            var nearestListIsOrdered: Bool?
            var column: Int?
            for component in components {
                switch component.kind {
                case .header(let level): block.kind = .heading(level)
                case .codeBlock(let language): block.kind = .code(language)
                case .thematicBreak: block.kind = .rule
                case .blockQuote: block.quoteDepth += 1
                case .listItem(let ordinal):
                    if listItem == nil { listItem = (component.identity, ordinal) }
                case .orderedList:
                    block.listDepth += 1
                    if nearestListIsOrdered == nil { nearestListIsOrdered = true }
                case .unorderedList:
                    block.listDepth += 1
                    if nearestListIsOrdered == nil { nearestListIsOrdered = false }
                case .tableCell(let index): column = index
                case .tableHeaderRow: block.rowID = component.identity; block.tableHeader = true
                case .tableRow: block.rowID = component.identity
                case .table(let columns):
                    block.tableID = component.identity
                    if let column, columns.indices.contains(column) {
                        switch columns[column].alignment {
                        case .center: block.alignment = .center
                        case .right: block.alignment = .trailing
                        default: break
                        }
                    }
                default: break
                }
            }
            if let item = listItem, markedItems.insert(item.id).inserted {
                block.marker = nearestListIsOrdered == true ? "\(item.ordinal)." : "•"
            }
            blocks.append(block)
        }
        return blocks
    }
}

struct MarkdownSection: Identifiable {
    var id: Int { blocks[0].tableID ?? blocks[0].id }
    var blocks: [MarkdownBlock]
    static func group(_ blocks: [MarkdownBlock]) -> [MarkdownSection] {
        var sections: [MarkdownSection] = []
        for block in blocks {
            if let tableID = block.tableID, sections.last?.blocks.first?.tableID == tableID {
                sections[sections.count - 1].blocks.append(block)
            } else { sections.append(MarkdownSection(blocks: [block])) }
        }
        return sections
    }
}

struct MarkdownSummary: View {
    var source: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownSection.group(MarkdownBlock.parse(source))) { section in
                if section.blocks[0].tableID != nil { table(section.blocks) }
                else { blockView(section.blocks[0]) }
            }
        }
        .font(.system(size: 12)).foregroundStyle(Palette.body)
        .tint(Palette.accent).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockView(_ block: MarkdownBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if block.quoteDepth > 0 { Rectangle().fill(Palette.accent.opacity(0.35)).frame(width: 3) }
            if block.listDepth > 0 {
                Text(block.marker ?? "").foregroundStyle(Palette.muted).frame(minWidth: 18, alignment: .trailing)
            }
            blockContent(block)
        }
        .padding(.leading, CGFloat(max(0, block.listDepth - 1) * 18 + max(0, block.quoteDepth - 1) * 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func blockContent(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text).font(.system(size: level == 1 ? 22 : level == 2 ? 18 : 14, weight: .semibold))
                .foregroundStyle(Palette.ink).padding(.top, 5).accessibilityAddTraits(.isHeader)
        case .code(let language):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty { Text(language).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }
                ScrollView(.horizontal) {
                    Text(String(block.text.characters).trimmingCharacters(in: .newlines))
                        .font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: true, vertical: true)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
        case .rule: Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 5)
        case .paragraph: Text(block.text).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func table(_ blocks: [MarkdownBlock]) -> some View {
        let rowIDs = blocks.compactMap(\.rowID).reduce(into: [Int]()) { rows, id in
            if rows.last != id { rows.append(id) }
        }
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rowIDs, id: \.self) { rowID in
                    GridRow {
                        ForEach(blocks.filter { $0.rowID == rowID }) { cell in
                            Text(cell.text).fontWeight(cell.tableHeader ? .semibold : .regular)
                                .padding(9).frame(minWidth: 100, maxWidth: 280, alignment: cell.alignment)
                                .background(cell.tableHeader ? Palette.quiet : Palette.card)
                                .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                        }
                    }
                }
            }
        }
    }
}
