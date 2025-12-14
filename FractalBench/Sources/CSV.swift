import Foundation

enum CSV {
    static func write(path: String, header: String, rows: [String]) throws {
        var out = header + "\n"
        out += rows.joined(separator: "\n")
        out += "\n"
        try out.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }
}
