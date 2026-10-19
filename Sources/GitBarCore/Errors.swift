import Foundation

/// Every failure surfaced by GitBar carries a stable, machine-readable `code`.
/// The CLI maps codes to exit statuses (see `exitCode`) so agents can branch on them.
public struct GitBarError: Error, Codable, CustomStringConvertible, Sendable, Equatable {
    public var code: String
    public var message: String
    public var hint: String?
    public var stderr: String?

    public init(code: String, message: String, hint: String? = nil, stderr: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.stderr = stderr
    }

    public var description: String { message }

    public var exitCode: Int32 {
        switch code {
        case "usage": return 2
        case "no_project", "project_not_found", "config_invalid", "duplicate_project": return 3
        case "not_a_repo": return 4
        case "nothing_to_commit", "nothing_to_abort": return 5
        case "auth_failed": return 6
        case "push_rejected": return 7
        case "conflict": return 8
        case "no_remote", "no_upstream", "detached_head", "no_commits": return 9
        case "identity_missing": return 10
        default: return 1
        }
    }

    /// Documented exit codes, shown in `gitbar help` and `gitbar help --json`.
    public static let exitCodeTable: [(Int32, String)] = [
        (0, "success"),
        (1, "git_failed / other error"),
        (2, "usage: bad command, option or value"),
        (3, "no_project, project_not_found, duplicate_project, config_invalid"),
        (4, "not_a_repo"),
        (5, "nothing_to_commit, nothing_to_abort"),
        (6, "auth_failed: GitHub credentials missing or rejected"),
        (7, "push_rejected: remote has commits you don't have (pull first)"),
        (8, "conflict: pull produced merge/rebase conflicts"),
        (9, "no_remote, no_upstream, detached_head, no_commits"),
        (10, "identity_missing: git user.name / user.email not set"),
    ]

    public static func usage(_ message: String, hint: String? = nil) -> GitBarError {
        GitBarError(code: "usage", message: message, hint: hint ?? "Run `gitbar help` for usage.")
    }
}
