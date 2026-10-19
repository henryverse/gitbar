import Foundation

/// One-line, human-readable descriptions shared by the CLI and the menu bar app.
public extension CommitResult {
    var summary: String {
        "Committed \(shortSha) (\(files.count) file\(files.count == 1 ? "" : "s")): \(message)"
    }
}

public extension PushResult {
    var summary: String {
        if upToDate { return "Already up to date with \(remote)/\(branch)." }
        let what = commitsPushed.map { "\($0) commit\($0 == 1 ? "" : "s")" } ?? branch
        return "Pushed \(what) to \(remote)/\(branch)" + (setUpstream ? " (upstream set)." : ".")
    }
}

public extension PullResult {
    var summary: String {
        updated
            ? "Pulled \(commitsPulled) commit\(commitsPulled == 1 ? "" : "s") into \(branch) (\(strategy))."
            : "Already up to date; nothing to pull."
    }
}

public extension SyncResult {
    var summary: String {
        [commit?.summary ?? "Nothing to commit.", pull?.summary, push.summary]
            .compactMap { $0 }.joined(separator: " ")
    }
}

public extension RepoStatus {
    var trackingSummary: String {
        if let inProgress { return "\(inProgress) in progress — resolve conflicts or run `gitbar abort`" }
        guard let branch else { return "detached HEAD" }
        guard let upstream else { return "\(branch) (not pushed yet)" }
        var parts: [String] = []
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return "\(branch) → \(upstream)" + (parts.isEmpty ? " (in sync)" : " " + parts.joined(separator: " "))
    }
}
