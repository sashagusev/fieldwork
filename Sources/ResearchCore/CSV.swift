import Foundation

public enum CSV {
    // Works on UTF-8 bytes: every delimiter is ASCII, and stepping through Characters made large files take seconds.
    public static func parse(_ source: String) throws -> [[String]] { try parse(Array(source.utf8)) }
    public static func parse(_ source: [UInt8]) throws -> [[String]] {
        var start = 0
        if source.count >= 3, source[0] == 0xEF, source[1] == 0xBB, source[2] == 0xBF { start = 3 }
        if start == source.count { return [] }
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), lineFeed = UInt8(ascii: "\n"), carriageReturn = UInt8(ascii: "\r")
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        var quoted = false, closed = false, i = start
        func endField() { row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true); closed = false }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < source.count {
            let byte = source[i]
            if quoted {
                if byte == quote {
                    if i + 1 < source.count, source[i + 1] == quote { field.append(quote); i += 2; continue }
                    quoted = false; closed = true
                } else { field.append(byte) }
            } else if byte == quote {
                guard field.isEmpty && !closed else { throw ResearchError("Invalid quote in CSV row \(rows.count + 1).") }
                quoted = true
            } else if byte == comma { endField() }
            else if byte == lineFeed { endRow() }
            else if byte == carriageReturn { if i + 1 < source.count, source[i + 1] == lineFeed { i += 1 }; endRow() }
            else {
                guard !closed else { throw ResearchError("Unexpected text after a closing CSV quote in row \(rows.count + 1).") }
                field.append(byte)
            }
            i += 1
        }
        guard !quoted else { throw ResearchError("Unclosed quoted field in CSV row \(rows.count + 1).") }
        if !row.isEmpty || !field.isEmpty || closed || source.last == comma { endRow() }
        return rows
    }
    public static func encode(_ rows: [[String]]) -> String {
        rows.map { row in row.map { value in
            if value.utf8.contains(where: { $0 == 44 || $0 == 34 || $0 == 10 || $0 == 13 }) { return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return value
        }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
    static func dictionaries(_ source: String, columns: [String], filename: String) throws -> [[String: String]] {
        let rows = try parse(source)
        guard let header = rows.first, Set(header) == Set(columns), header.count == columns.count else {
            throw ResearchError("\(filename) has unexpected columns. Expected: \(columns.joined(separator: ", ")).")
        }
        return try rows.dropFirst().enumerated().map { index, row in
            guard row.count == header.count else { throw ResearchError("\(filename), row \(index + 2): expected \(header.count) fields, found \(row.count).") }
            return Dictionary(uniqueKeysWithValues: zip(header, row))
        }
    }
}
