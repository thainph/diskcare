/// Prints an aligned plain-text table, indented by `indent` spaces.
func table(headers: [String], rows: [[String]], rightAligned: Set<Int>, indent: Int = 2) {
    let prefix = String(repeating: " ", count: indent)
    guard !rows.isEmpty else {
        Swift.print(prefix + "(none)")
        return
    }
    let widths = headers.indices.map { column in
        ([headers] + rows).map { $0[column].count }.max() ?? 0
    }
    for row in [headers] + rows {
        let cells = row.enumerated().map { column, cell in
            let padding = String(repeating: " ", count: widths[column] - cell.count)
            return rightAligned.contains(column) ? padding + cell : cell + padding
        }
        var line = prefix + cells.joined(separator: "  ")
        while line.hasSuffix(" ") { line.removeLast() }
        Swift.print(line)
    }
}
