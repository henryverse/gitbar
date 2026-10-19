import Foundation

public struct FileChange: Codable, Sendable, Hashable {
    /// added | modified | deleted | renamed | copied | typechange | untracked | conflicted
    public let kind: String
    public let path: String
    public let originalPath: String?
    /// Raw porcelain XY code, e.g. "M." (staged) or ".M" (unstaged), "??" for untracked.
    public let xy: String
    public let staged: Bool
}

public struct RepoStatus: Codable, Sendable {
    public let project: String
    public let path: String
    public let branch: String?
    public let detached: Bool
    public let hasCommits: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let remotes: [String]
    public let remoteURL: String?
    public let changes: [FileChange]
    public let clean: Bool
    public let conflicted: Bool
    /// "rebase" | "merge" | "cherry-pick" | "revert" while one is stopped mid-way, else nil.
    public let inProgress: String?
}

public struct AbortResult: Codable, Sendable {
    public let aborted: String
}

public struct CommitResult: Codable, Sendable {
    public let sha: String
    public let shortSha: String
    public let branch: String?
    public let message: String
    public let files: [String]
}

public struct PushResult: Codable, Sendable {
    public let remote: String
    public let branch: String
    public let setUpstream: Bool
    public let commitsPushed: Int?
    public let upToDate: Bool
    public let output: String
}

public struct PullResult: Codable, Sendable {
    public let remote: String?
    public let branch: String
    public let strategy: String
    public let updated: Bool
    public let commitsPulled: Int
    public let fromSha: String?
    public let toSha: String?
    public let output: String
}

public struct SyncResult: Codable, Sendable {
    public let commit: CommitResult?
    public let pull: PullResult?
    public let push: PushResult
}

public struct RemoteInfo: Codable, Sendable {
    public let name: String
    public let url: String
}

public struct Repo: Sendable {
    public let project: Project
    public let config: Config
    let git: GitRunner

    public init(project: Project, config: Config) {
        self.project = project
        self.config = config
        self.git = GitRunner(config: config)
    }

    var path: String { project.path }

    func ensureRepo() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw GitBarError(code: "project_not_found", message: "Project folder \(path) no longer exists.",
                              hint: "Remove it with `gitbar project remove \(project.name)` or re-add the new location.")
        }
        let r = try git.run(["rev-parse", "--git-dir"], in: path)
        if r.status != 0 { throw GitRunner.classify(r, args: ["rev-parse"]) }
    }

    // MARK: Status

    public func status(fetch: Bool = false) throws -> RepoStatus {
        try ensureRepo()
        let remotes = try remoteNames()
        if fetch, !remotes.isEmpty {
            try git.checked(["fetch", "--prune", fetchRemote(remotes: remotes)], in: path)
        }
        let raw = try git.checked(["status", "--porcelain=v2", "--branch", "-z"], in: path).stdout
        var branch: String?, upstream: String?
        var ahead = 0, behind = 0, hasCommits = true, detached = false
        var changes: [FileChange] = []

        var records = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let rec = records.popFirst() {
            if rec.hasPrefix("# ") {
                let parts = rec.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": hasCommits = parts[1] != "(initial)"
                case "branch.head":
                    if parts[1] == "(detached)" { detached = true } else { branch = parts[1] }
                case "branch.upstream": upstream = parts[1]
                case "branch.ab":
                    let ab = parts[1].split(separator: " ")
                    if ab.count == 2 {
                        ahead = Int(ab[0].dropFirst()) ?? 0
                        behind = Int(ab[1].dropFirst()) ?? 0
                    }
                default: break
                }
                continue
            }
            let type = rec.first
            switch type {
            case "1":
                let f = rec.split(separator: " ", maxSplits: 8).map(String.init)
                guard f.count == 9 else { continue }
                changes.append(Repo.change(xy: f[1], path: f[8], original: nil))
            case "2":
                let f = rec.split(separator: " ", maxSplits: 9).map(String.init)
                guard f.count == 10 else { continue }
                let original = records.popFirst()
                changes.append(Repo.change(xy: f[1], path: f[9], original: original))
            case "u":
                let f = rec.split(separator: " ", maxSplits: 10).map(String.init)
                guard f.count == 11 else { continue }
                changes.append(FileChange(kind: "conflicted", path: f[10], originalPath: nil, xy: f[1], staged: false))
            case "?":
                changes.append(FileChange(kind: "untracked", path: String(rec.dropFirst(2)), originalPath: nil, xy: "??", staged: false))
            default:
                continue
            }
        }

        let urlRemote = remotes.contains(config.defaultRemote) ? config.defaultRemote : remotes.first
        let remoteURL = urlRemote.flatMap { try? git.output(["remote", "get-url", $0], in: path) }
        return RepoStatus(project: project.name, path: path, branch: branch, detached: detached,
                          hasCommits: hasCommits, upstream: upstream, ahead: ahead, behind: behind,
                          remotes: remotes, remoteURL: remoteURL, changes: changes, clean: changes.isEmpty,
                          conflicted: changes.contains { $0.kind == "conflicted" },
                          inProgress: try operationInProgress())
    }

    func operationInProgress() throws -> String? {
        let raw = try git.output(["rev-parse", "--git-dir"], in: path)
        let gitDir = raw.hasPrefix("/") ? raw : (path as NSString).appendingPathComponent(raw)
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent(name)) }
        if exists("rebase-merge") || exists("rebase-apply") { return "rebase" }
        if exists("MERGE_HEAD") { return "merge" }
        if exists("CHERRY_PICK_HEAD") { return "cherry-pick" }
        if exists("REVERT_HEAD") { return "revert" }
        return nil
    }

    /// Abort a stopped rebase/merge/cherry-pick/revert, restoring the pre-operation state.
    public func abort() throws -> AbortResult {
        try ensureRepo()
        guard let op = try operationInProgress() else {
            throw GitBarError(code: "nothing_to_abort", message: "No rebase or merge is in progress.")
        }
        try git.checked([op, "--abort"], in: path)
        return AbortResult(aborted: op)
    }

    static func change(xy: String, path: String, original: String?) -> FileChange {
        let chars = Array(xy)
        let x = chars.first ?? ".", y = chars.count > 1 ? chars[1] : "."
        let code = x != "." ? x : y
        let kind: String
        switch code {
        case "A": kind = "added"
        case "D": kind = "deleted"
        case "R": kind = "renamed"
        case "C": kind = "copied"
        case "T": kind = "typechange"
        default: kind = "modified"
        }
        return FileChange(kind: kind, path: path, originalPath: original, xy: xy, staged: x != ".")
    }

    // MARK: Commit

    public func commit(message: String?, stageAll: Bool? = nil) throws -> CommitResult {
        try ensureRepo()
        let all = stageAll ?? config.stageAll
        if all { try git.checked(["add", "-A"], in: path) }
        let staged = try git.checked(["diff", "--cached", "--name-only", "-z"], in: path).stdout
            .split(separator: "\0").map(String.init)
        guard !staged.isEmpty else {
            throw GitBarError(code: "nothing_to_commit", message: "Nothing to commit; the working tree is clean.",
                              hint: all ? nil : "Stage files with `git add`, or pass `--all` to stage everything.")
        }
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let msg = trimmed.isEmpty ? Repo.autoMessage(for: staged) : trimmed
        try git.checked(["commit", "-m", msg], in: path)
        let sha = try git.output(["rev-parse", "HEAD"], in: path)
        let branch = try? git.output(["symbolic-ref", "--short", "-q", "HEAD"], in: path)
        return CommitResult(sha: sha, shortSha: String(sha.prefix(7)), branch: branch, message: msg, files: staged)
    }

    public static func autoMessage(for files: [String]) -> String {
        let names = files.map { ($0 as NSString).lastPathComponent }
        switch names.count {
        case 1: return "Update \(names[0])"
        case 2...3: return "Update " + names.joined(separator: ", ")
        default: return "Update \(names.count) files (\(names.prefix(3).joined(separator: ", ")), …)"
        }
    }

    // MARK: Push / Pull

    public func push(remote: String? = nil, forceWithLease: Bool = false,
                     progress: ProgressHandler? = nil) throws -> PushResult {
        let st = try status()
        let branch = try requireBranch(st)
        guard !st.remotes.isEmpty else { throw noRemote() }
        guard st.hasCommits else {
            throw GitBarError(code: "no_commits", message: "There are no commits to push yet.",
                              hint: "Commit first with `gitbar commit`.")
        }
        var args = ["push"]
        if forceWithLease { args.append("--force-with-lease") }
        let target: String
        let setUpstream: Bool
        if st.upstream != nil, remote == nil {
            target = (try? git.output(["config", "branch.\(branch).remote"], in: path)) ?? config.defaultRemote
            setUpstream = false
        } else {
            target = try pickRemote(remote, remotes: st.remotes)
            args += ["-u", target, branch]
            setUpstream = st.upstream == nil
        }
        let r = try git.checked(args, in: path, progress: progress)
        let output = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return PushResult(remote: target, branch: branch, setUpstream: setUpstream,
                          commitsPushed: st.upstream == nil ? nil : st.ahead,
                          upToDate: output.contains("Everything up-to-date"), output: output)
    }

    public func pull(strategy: PullStrategy? = nil, remote: String? = nil,
                     progress: ProgressHandler? = nil) throws -> PullResult {
        let st = try status()
        let branch = try requireBranch(st)
        guard !st.remotes.isEmpty else { throw noRemote() }
        let strat = strategy ?? config.pullStrategy
        let before = st.hasCommits ? try git.output(["rev-parse", "HEAD"], in: path) : nil
        var args = ["pull"] + strat.gitFlags
        var target: String?
        if st.upstream == nil || remote != nil {
            let r = try pickRemote(remote, remotes: st.remotes)
            target = r
            args += [r, branch]
        } else {
            target = try? git.output(["config", "branch.\(branch).remote"], in: path)
        }
        let r = try git.checked(args, in: path, progress: progress)
        let after = try? git.output(["rev-parse", "HEAD"], in: path)
        let updated = before != after
        var count = 0
        if updated {
            // Commits that came from the remote, not local commits replayed by a rebase.
            let range = before.map { "\($0)..FETCH_HEAD" } ?? "FETCH_HEAD"
            count = Int((try? git.output(["rev-list", "--count", range], in: path)) ?? "") ?? 0
        }
        return PullResult(remote: target, branch: branch, strategy: strat.rawValue, updated: updated,
                          commitsPulled: count, fromSha: before, toSha: after,
                          output: (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Commit everything (if there's anything), pull, then push.
    public func sync(message: String?, strategy: PullStrategy? = nil, stageAll: Bool? = nil,
                     progress: ProgressHandler? = nil) throws -> SyncResult {
        var commit: CommitResult?
        do {
            commit = try self.commit(message: message, stageAll: stageAll)
        } catch let e as GitBarError where e.code == "nothing_to_commit" {}
        var pull: PullResult?
        do {
            pull = try self.pull(strategy: strategy ?? config.syncPullStrategy, progress: progress)
        } catch let e as GitBarError where e.code == "no_upstream" {
            // New branch: nothing on the remote to pull yet; push will create it.
        }
        return SyncResult(commit: commit, pull: pull, push: try push(progress: progress))
    }

    // MARK: Remotes

    public func remotes() throws -> [RemoteInfo] {
        try ensureRepo()
        return try remoteNames().map { name in
            RemoteInfo(name: name, url: (try? git.output(["remote", "get-url", name], in: path)) ?? "")
        }
    }

    public func setRemote(url: String, name: String? = nil) throws -> [RemoteInfo] {
        try ensureRepo()
        let n = name ?? config.defaultRemote
        if try remoteNames().contains(n) {
            try git.checked(["remote", "set-url", n, url], in: path)
        } else {
            try git.checked(["remote", "add", n, url], in: path)
        }
        return try remotes()
    }

    // MARK: Helpers

    func remoteNames() throws -> [String] {
        try git.output(["remote"], in: path).split(separator: "\n").map(String.init)
    }

    func fetchRemote(remotes: [String]) -> String {
        remotes.contains(config.defaultRemote) ? config.defaultRemote : remotes[0]
    }

    func pickRemote(_ explicit: String?, remotes: [String]) throws -> String {
        if let explicit {
            guard remotes.contains(explicit) else {
                throw GitBarError(code: "no_remote", message: "No remote named '\(explicit)'.",
                                  hint: "Existing remotes: \(remotes.joined(separator: ", ")).")
            }
            return explicit
        }
        return fetchRemote(remotes: remotes)
    }

    func requireBranch(_ st: RepoStatus) throws -> String {
        guard let b = st.branch, !st.detached else {
            throw GitBarError(code: "detached_head", message: "HEAD is detached; check out a branch first.",
                              hint: "Run `git switch <branch>` in \(path).")
        }
        return b
    }

    func noRemote() -> GitBarError {
        GitBarError(code: "no_remote", message: "This project has no GitHub remote.",
                    hint: "Add one with `gitbar remote set https://github.com/<owner>/<repo>.git`.")
    }
}
