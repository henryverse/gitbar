import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

/// Runs git non-interactively: no terminal prompts, no editors, batch-mode SSH.
/// A command that would need input fails fast with an `auth_failed`-style error
/// instead of hanging the menu bar app or an agent.
public struct GitRunner: Sendable {
    public let executable: String

    public init(config: Config) {
        let env = ProcessInfo.processInfo.environment
        executable = env["GITBAR_GIT"].flatMap { $0.isEmpty ? nil : $0 } ?? config.gitPath ?? "/usr/bin/git"
    }

    /// With `progress`, git is asked for `--progress` output and each percentage update is
    /// reported as it arrives; those lines are left out of the returned stderr.
    public func run(_ args: [String], in directory: String, progress: ProgressHandler? = nil) throws -> CommandResult {
        var sshCommand: String?
        if ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil,
           ["push", "pull", "fetch", "ls-remote", "clone"].contains(args.first ?? "") {
            // Keep the repo's own core.sshCommand (e.g. a per-repo key) and just make it non-interactive.
            let configured = try? spawn(["config", "--get", "core.sshCommand"], in: directory, sshCommand: nil)
            let base = configured.flatMap { $0.status == 0 ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            sshCommand = (base?.isEmpty == false ? base! : "ssh") + " -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        }
        var args = args
        if progress != nil, !args.isEmpty { args.insert("--progress", at: 1) }
        return try spawn(args, in: directory, sshCommand: sshCommand, progress: progress)
    }

    private func spawn(_ args: [String], in directory: String, sshCommand: String?,
                       progress: ProgressHandler? = nil) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)

        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = ":"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        env["GIT_SEQUENCE_EDITOR"] = ":"
        if let sshCommand { env["GIT_SSH_COMMAND"] = sshCommand }
        // GUI apps launched from Finder get a minimal PATH; credential helpers (gh, git-lfs) live elsewhere.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (path + extra.filter { !path.contains($0) }).joined(separator: ":")
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GitBarError(code: "git_failed",
                              message: "Could not launch git at \(executable): \(error.localizedDescription)",
                              hint: "Install Xcode Command Line Tools (xcode-select --install) or set `gitbar config set gitPath <path>`.")
        }

        // Drain both pipes concurrently so a chatty command can't deadlock on a full buffer.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if let progress {
            errData = Self.readProgress(errPipe.fileHandleForReading, progress)
        } else {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        group.wait()
        process.waitUntilExit()

        return CommandResult(status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Reads stderr as it arrives. git redraws progress with `\r`; those redraws go to `handler`
    /// and are dropped, while `\n`-terminated lines (including each phase's final ", done.") are kept.
    private static func readProgress(_ handle: FileHandle, _ handler: ProgressHandler) -> Data {
        var kept = Data(), pending = Data()
        func emit(_ segment: Data) {
            if let p = TransferProgress.parse(String(decoding: segment, as: UTF8.self)) { handler(p) }
        }
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let i = pending.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
                let segment = pending[pending.startIndex..<i]
                emit(segment)
                if pending[i] == 0x0A { kept.append(segment); kept.append(0x0A) }
                pending.removeSubrange(pending.startIndex...i)
            }
        }
        kept.append(pending)
        return kept
    }

    /// Runs git and throws a classified `GitBarError` on non-zero exit. Returns raw stdout.
    @discardableResult
    public func checked(_ args: [String], in directory: String, progress: ProgressHandler? = nil) throws -> CommandResult {
        let result = try run(args, in: directory, progress: progress)
        guard result.status == 0 else { throw GitRunner.classify(result, args: args) }
        return result
    }

    public func output(_ args: [String], in directory: String) throws -> String {
        try checked(args, in: directory).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func classify(_ result: CommandResult, args: [String]) -> GitBarError {
        let text = result.stderr + "\n" + result.stdout
        let lower = text.lowercased()
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = args.first ?? "git"
        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0.lowercased()) } }

        if has("not a git repository") {
            return GitBarError(code: "not_a_repo", message: "Not a git repository.",
                               hint: "Run `gitbar project add <path> --init` to initialize it.", stderr: stderr)
        }
        if has("authentication failed", "could not read username", "could not read password",
               "permission denied (publickey", "terminal prompts disabled", "host key verification failed",
               "invalid username or password", "403") && ["push", "pull", "fetch", "ls-remote"].contains(sub) {
            return GitBarError(code: "auth_failed", message: "GitHub rejected the credentials for \(sub).",
                               hint: "Set up access once in Terminal: `gh auth login` (HTTPS) or add an SSH key to GitHub, then retry.",
                               stderr: stderr)
        }
        if sub == "push" && has("[rejected]", "non-fast-forward", "fetch first", "updates were rejected") {
            return GitBarError(code: "push_rejected", message: "Push rejected: the remote has commits you don't have.",
                               hint: "Pull first (`gitbar pull --strategy rebase`) or use `gitbar sync`.", stderr: stderr)
        }
        if has("conflict (", "merge conflict", "could not apply", "fix conflicts", "resolve all conflicts") {
            return GitBarError(code: "conflict", message: "\(sub.capitalized) stopped because of conflicts.",
                               hint: "Run `gitbar abort` to undo, or resolve the files, `git add` them and run `git rebase --continue` (or `git commit` for a merge).",
                               stderr: stderr.isEmpty ? result.stdout : stderr)
        }
        if sub == "pull" && has("not possible to fast-forward", "diverging branches", "need to specify how to reconcile") {
            return GitBarError(code: "conflict", message: "Local and remote branches have diverged; fast-forward is not possible.",
                               hint: "Retry with `--strategy rebase` or `--strategy merge` (or set `gitbar config set pullStrategy rebase`).",
                               stderr: stderr)
        }
        if has("couldn't find remote ref") {
            return GitBarError(code: "no_upstream", message: "The branch does not exist on the remote yet.",
                               hint: "Push it first with `gitbar push`.", stderr: stderr)
        }
        if has("please tell me who you are", "unable to auto-detect email", "empty ident name") {
            return GitBarError(code: "identity_missing", message: "Git doesn't know your name and email.",
                               hint: "Run `git config --global user.name \"Your Name\"` and `git config --global user.email you@example.com`.",
                               stderr: stderr)
        }
        if has("could not resolve host", "unable to access", "connection timed out", "network is unreachable") {
            return GitBarError(code: "network", message: "Couldn't reach the remote.",
                               hint: "Check your internet connection and the remote URL (`gitbar remote`).", stderr: stderr)
        }
        let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? "exit status \(result.status)"
        return GitBarError(code: "git_failed", message: "git \(sub) failed: \(firstLine)", stderr: stderr)
    }
}
