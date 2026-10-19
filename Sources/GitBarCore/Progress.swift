import Foundation

/// A transfer progress update parsed from git's `--progress` output, e.g.
/// `Writing objects:  34% (71/208), 23.50 MiB | 41.00 KiB/s`.
public struct TransferProgress: Sendable, Equatable {
    /// Uploading | Downloading | Compressing | Preparing | Processing on remote
    public let phase: String
    public let percent: Int
    /// Amount transferred so far, e.g. "23.5 MB" (only while uploading/downloading).
    public let transferred: String?
    /// Current speed, e.g. "41 KB/s" (only while uploading/downloading).
    public let rate: String?

    /// "Uploading 34% · 23.5 MB · 41 KB/s"
    public var summary: String {
        ([phase + " \(percent)%"] + [transferred, rate].compactMap { $0 }).joined(separator: " · ")
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(remote: )?([A-Za-z ]+):\s+(\d+)% \(\d+/\d+\)(?:, ([\d.]+ [KMG]?i?B))?(?: \| ([\d.]+ [KMG]?i?B/s))?"#)

    private static let phases = [
        "Writing objects": "Uploading",
        "Receiving objects": "Downloading",
        "Compressing objects": "Compressing",
        "Counting objects": "Preparing",
        "Resolving deltas": "Resolving",
    ]

    /// Parses one progress line; returns nil for anything that isn't a percentage update.
    public static func parse(_ line: String) -> TransferProgress? {
        let ns = line as NSString
        guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        guard let label = group(2), let percent = group(3).flatMap(Int.init) else { return nil }
        let phase = group(1) != nil ? "Processing on remote" : (phases[label] ?? label)
        return TransferProgress(phase: phase, percent: percent,
                                transferred: group(4).map(tidy), rate: group(5).map(tidy))
    }

    /// "23.50 MiB" → "23.5 MB", "41.00 KiB/s" → "41 KB/s".
    private static func tidy(_ s: String) -> String {
        var parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        if let n = Double(parts[0]) {
            parts[0] = n >= 100 || n == n.rounded() ? String(Int(n.rounded())) : String(format: "%.1f", n)
        }
        return parts.joined(separator: " ").replacingOccurrences(of: "iB", with: "B")
    }
}

public typealias ProgressHandler = @Sendable (TransferProgress) -> Void
