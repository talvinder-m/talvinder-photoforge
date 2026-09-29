import Foundation

/// Batch naming. Patterns use tokens:
///   {name}   current name (without extension)      {n}      sequence number (padded)
///   {date}   capture date, yyyy-MM-dd               {year} {month} {day}
///   {time}   capture time, HH-mm-ss                 {camera} camera model (or "")
/// Example: "Farm Visit {date} {n}" → "Farm Visit 2024-03-12 001".
public struct BatchRename: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable, Identifiable {
        case pattern, findReplace, prefixSuffix
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .pattern: "Name pattern"
            case .findReplace: "Find & replace"
            case .prefixSuffix: "Add prefix / suffix"
            }
        }
    }
    public var mode: Mode = .pattern
    public var pattern = "{name}"
    public var start = 1
    public var padding = 3
    public var find = ""
    public var replace = ""
    public var caseSensitive = false
    public var prefix = ""
    public var suffix = ""
    public init() {}

    public struct Item: Sendable {
        public let currentName: String       // may include an extension; it is kept separately
        public let date: Date?
        public let camera: String?
        public init(currentName: String, date: Date?, camera: String?) {
            self.currentName = currentName; self.date = date; self.camera = camera
        }
    }

    /// New base names (no extension), in order. Empty results fall back to the current name.
    public func apply(to items: [Item]) -> [String] {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        return items.enumerated().map { i, item in
            let base = Self.stripExtension(item.currentName)
            var out: String
            switch mode {
            case .pattern:
                out = pattern
                let n = String(repeating: "0", count: max(0, padding - String(start + i).count)) + String(start + i)
                func fmt(_ f: String) -> String {
                    guard let d = item.date else { return "" }
                    df.dateFormat = f
                    return df.string(from: d)
                }
                let tokens: [String: String] = [
                    "{name}": base, "{n}": n, "{date}": fmt("yyyy-MM-dd"), "{year}": fmt("yyyy"), "{month}": fmt("MM"),
                    "{day}": fmt("dd"), "{time}": fmt("HH-mm-ss"), "{camera}": item.camera ?? "",
                ]
                for (k, v) in tokens { out = out.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
            case .findReplace:
                out = find.isEmpty ? base
                    : base.replacingOccurrences(of: find, with: replace, options: caseSensitive ? [] : .caseInsensitive)
            case .prefixSuffix:
                out = prefix + base + suffix
            }
            out = Self.clean(out)
            return out.isEmpty ? base : out
        }
    }

    /// Makes names unique within the batch by appending " 2", " 3", … to repeats.
    public static func uniqued(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { n in
            let key = n.lowercased()
            if let c = seen[key] { seen[key] = c + 1; return "\(n) \(c + 1)" }
            seen[key] = 1
            return n
        }
    }

    public static func stripExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return name }
        return (name as NSString).deletingPathExtension
    }

    /// No path separators or control characters; collapsed whitespace.
    public static func clean(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let t = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Grouping key for "group by name": the name without a trailing counter or date-ish suffix,
    /// e.g. "Farm Visit 012" and "Farm Visit-013" → "Farm Visit"; "IMG_4021" → "IMG".
    public static func nameStem(_ name: String) -> String {
        var s = stripExtension(name)
        let pattern = #"[\s_\-\.]*(\(\d+\)|\d+)$"#
        while let r = s.range(of: pattern, options: .regularExpression), r.lowerBound != s.startIndex {
            s.removeSubrange(r)
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        return s.isEmpty ? stripExtension(name) : s
    }
}
