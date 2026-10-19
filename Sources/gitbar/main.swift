import AppKit
import Foundation
import GitBarCore

// MARK: Output

struct Envelope<T: Encodable>: Encodable {
    let ok: Bool
    let command: String
    let result: T?
    let error: GitBarError?
}

struct Empty: Encodable {}

final class Output {
    let json: Bool
    init(json: Bool) { self.json = json }

    static func encode<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    func success<T: Encodable>(_ command: String, _ result: T, human: () -> String) {
        if json {
            print(Output.encode(Envelope(ok: true, command: command, result: result, error: nil)))
        } else {
            let text = human()
            if !text.isEmpty { print(text) }
        }
    }

    func failure(_ command: String, _ error: GitBarError) {
        if json {
            print(Output.encode(Envelope<Empty>(ok: false, command: command, result: nil, error: error)))
        } else {
            var text = "error: \(error.message)"
            if let hint = error.hint { text += "\nhint: \(hint)" }
            if let stderr = error.stderr, !stderr.isEmpty, error.code == "git_failed" {
                text += "\n\n" + stderr
            }
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
    }
}

// MARK: Help

func helpText(for command: CommandSpec?) -> String {
    if let c = command {
        var lines = ["\(c.summary)", "", "Usage: \(c.usage)"]
        do {
            lines.append("")
            lines.append("Options:")
            for o in c.options + globalOptions {
                let flag = ([o.short, o.name].compactMap { $0 }.joined(separator: ", ")) + (o.value.map { " <\($0)>" } ?? "")
                lines.append("  " + flag.padding(toLength: 34, withPad: " ", startingAt: 0) + o.description)
            }
        }
        if c.name == "config set" || c.name == "config get" {
            lines.append("")
            lines.append("Keys:")
            for k in Config.settableKeys {
                lines.append("  " + k.key.padding(toLength: 18, withPad: " ", startingAt: 0) + "\(k.type), default \(k.defaultValue). \(k.description)")
            }
        }
        return lines.joined(separator: "\n")
    }
    var lines = [
        "gitbar \(GitBarInfo.version) — commit, push and pull GitHub projects from the menu bar or the shell.",
        "",
        "Usage: gitbar <command> [options]",
        "",
        "Commands:",
    ]
    for c in commands {
        lines.append("  " + (c.name + " " + c.arguments.joined(separator: " ")).padding(toLength: 30, withPad: " ", startingAt: 0) + c.summary)
    }
    lines += [
        "",
        "Global options:",
        "  --json                        Machine-readable output: {\"ok\":true,\"command\":…,\"result\":…} or {\"ok\":false,\"error\":{code,message,hint}}.",
        "  -h, --help                    Help for a command, e.g. `gitbar push --help`.",
        "",
        "Project selection: --project <name|path>, else $GITBAR_PROJECT, else the current project (`gitbar project use`).",
        "The menu bar app and the CLI share \(ConfigStore.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")); changes appear in the app within refreshInterval seconds.",
        "Git never prompts: missing credentials fail fast with code auth_failed.",
        "",
        "Exit codes:",
    ]
    for (code, meaning) in GitBarError.exitCodeTable { lines.append("  \(code)".padding(toLength: 6, withPad: " ", startingAt: 0) + meaning) }
    lines += ["", "Agents: `gitbar help --json` prints this spec as JSON."]
    return lines.joined(separator: "\n")
}

struct HelpSpec: Encodable {
    struct ExitCode: Encodable { let code: Int32; let meaning: String }
    let version: String
    let configPath: String
    let projectResolution: [String]
    let globalOptions: [OptionSpec]
    let commands: [CommandSpec]
    let configKeys: [Config.KeyInfo]
    let exitCodes: [ExitCode]
    let environment: [String: String]
}

// MARK: Human formatting

func describe(_ st: RepoStatus) -> String {
    var lines = [
        "Project:  \(st.project)  \(st.path)",
        "Branch:   \(st.trackingSummary)",
        "Remote:   " + (st.remoteURL ?? "(none — run `gitbar remote set <url>`)"),
    ]
    if st.clean {
        lines.append("Changes:  none")
    } else {
        lines.append("Changes:  \(st.changes.count)")
        let tag = ["added": "A", "modified": "M", "deleted": "D", "renamed": "R", "copied": "C",
                   "typechange": "T", "untracked": "?", "conflicted": "U"]
        for c in st.changes {
            lines.append("  \(tag[c.kind] ?? "M") \(c.path)" + (c.originalPath.map { "  (from \($0))" } ?? ""))
        }
    }
    return lines.joined(separator: "\n")
}

// MARK: Commands

func log(_ project: Project, _ action: String, _ body: () throws -> String) throws {
    do {
        let summary = try body()
        ActivityLog.append(ActivityEntry(source: "cli", project: project.name, action: action, ok: true, summary: summary))
    } catch let e as GitBarError {
        ActivityLog.append(ActivityEntry(source: "cli", project: project.name, action: action, ok: false,
                                         summary: e.message, errorCode: e.code))
        throw e
    }
}

/// Live transfer progress on stderr, only when it's a terminal (agents and pipes see nothing; stdout stays clean).
func withProgress<T>(_ body: (ProgressHandler?) throws -> T) rethrows -> T {
    guard isatty(STDERR_FILENO) != 0 else { return try body(nil) }
    defer { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    return try body { p in FileHandle.standardError.write(Data("\r\u{1B}[K\(p.summary)".utf8)) }
}

func strategy(_ inv: Invocation) throws -> PullStrategy? {
    guard let raw = inv.value("--strategy") else { return nil }
    guard let s = PullStrategy(rawValue: raw) else {
        throw GitBarError.usage("Invalid --strategy '\(raw)'; expected ff-only, rebase or merge.")
    }
    return s
}

func stageAll(_ inv: Invocation) throws -> Bool? {
    if inv.flag("--all") && inv.flag("--no-add") { throw GitBarError.usage("--all and --no-add are mutually exclusive.") }
    if inv.flag("--all") { return true }
    if inv.flag("--no-add") { return false }
    return nil
}

struct AppState: Encodable {
    let running: Bool
    let pid: Int32?
    let bundlePath: String?
}

func appState() -> AppState {
    let app = NSRunningApplication.runningApplications(withBundleIdentifier: GitBarInfo.bundleIdentifier).first
    let url = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: GitBarInfo.bundleIdentifier)
    return AppState(running: app != nil, pid: app?.processIdentifier, bundlePath: url?.path)
}

func run(_ inv: Invocation, _ out: Output) throws {
    let name = inv.command.name
    if inv.help || name == "help" {
        let target = inv.help ? inv.command : inv.arguments.first.flatMap { arg in
            commands.first { $0.name == arg } ?? groupDefaults[arg].flatMap { d in commands.first { $0.name == d } }
        }
        if inv.json {
            let env = [
                "GITBAR_PROJECT": "Default project (name or path) when --project is not given.",
                "GITBAR_JSON": "Set to 1 to always emit JSON.",
                "GITBAR_HOME": "Directory for config.json and activity.jsonl.",
                "GITBAR_GIT": "Path to the git executable.",
            ]
            let spec = HelpSpec(version: GitBarInfo.version, configPath: ConfigStore.configURL.path,
                                projectResolution: ["--project", "$GITBAR_PROJECT", "config.currentProject", "the only registered project"],
                                globalOptions: globalOptions, commands: target.map { [$0] } ?? commands,
                                configKeys: Config.settableKeys,
                                exitCodes: GitBarError.exitCodeTable.map { HelpSpec.ExitCode(code: $0.0, meaning: $0.1) },
                                environment: env)
            out.success("help", spec) { "" }
        } else {
            print(helpText(for: target))
        }
        return
    }

    let config = try ConfigStore.load()
    func project() throws -> Project { try Projects.resolve(inv.value("--project"), config: config) }

    switch name {
    case "version":
        out.success(name, ["version": GitBarInfo.version]) { "gitbar \(GitBarInfo.version)" }

    case "status":
        let p = try project()
        let st = try Repo(project: p, config: config).status(fetch: inv.flag("--fetch"))
        out.success(name, st) { describe(st) }

    case "commit":
        let p = try project()
        var result: CommitResult!
        try log(p, "commit") {
            result = try Repo(project: p, config: config).commit(message: inv.value("--message"), stageAll: try stageAll(inv))
            return result.summary
        }
        out.success(name, result) { result.summary }

    case "push":
        let p = try project()
        var result: PushResult!
        try log(p, "push") {
            result = try withProgress {
                try Repo(project: p, config: config).push(remote: inv.value("--remote"),
                                                          forceWithLease: inv.flag("--force-with-lease"), progress: $0)
            }
            return result.summary
        }
        out.success(name, result) { result.summary }

    case "pull":
        let p = try project()
        var result: PullResult!
        try log(p, "pull") {
            let strat = try strategy(inv)
            result = try withProgress {
                try Repo(project: p, config: config).pull(strategy: strat, remote: inv.value("--remote"), progress: $0)
            }
            return result.summary
        }
        out.success(name, result) { result.summary }

    case "sync":
        let p = try project()
        var result: SyncResult!
        try log(p, "sync") {
            let strat = try strategy(inv), all = try stageAll(inv)
            result = try withProgress {
                try Repo(project: p, config: config).sync(message: inv.value("--message"),
                                                          strategy: strat, stageAll: all, progress: $0)
            }
            return result.summary
        }
        out.success(name, result) { [result.commit?.summary ?? "Nothing to commit.", result.pull?.summary, result.push.summary]
            .compactMap { $0 }.joined(separator: "\n") }

    case "abort":
        let p = try project()
        var result: AbortResult!
        try log(p, "abort") {
            result = try Repo(project: p, config: config).abort()
            return "Aborted \(result.aborted)."
        }
        out.success(name, result) { "Aborted \(result.aborted); the branch is back to where it was." }

    case "project list":
        struct Listing: Encodable { let current: String?; let projects: [Project] }
        let current = try? Projects.resolve(nil, config: config).name
        out.success(name, Listing(current: current, projects: config.projects)) {
            config.projects.isEmpty
                ? "No projects. Add one with `gitbar project add <path>`."
                : config.projects.map { ($0.name == current ? "* " : "  ") + $0.name + "\t" + $0.path }.joined(separator: "\n")
        }

    case "project add":
        let r = try Projects.add(path: inv.arguments[0], name: inv.value("--name"),
                                 makeCurrent: inv.flag("--use"), initRepo: inv.flag("--init"))
        let isCurrent = r.config.currentProject == r.project.name
        struct Added: Encodable { let project: Project; let current: Bool }
        out.success(name, Added(project: r.project, current: isCurrent)) {
            "Added \(r.project.name) (\(r.project.path))" + (isCurrent ? " — now current." : ".")
        }

    case "project remove":
        let r = try Projects.remove(inv.arguments[0])
        out.success(name, ["removed": r.project.name, "current": r.config.currentProject ?? ""]) {
            "Removed \(r.project.name)." + (r.config.currentProject.map { " Current project: \($0)." } ?? "")
        }

    case "project use":
        let r = try Projects.use(inv.arguments[0])
        out.success(name, r.project) { "Current project: \(r.project.name) (\(r.project.path))" }

    case "project current":
        let p = try project()
        out.success(name, p) { "\(p.name)\t\(p.path)" }

    case "remote show":
        let p = try project()
        let remotes = try Repo(project: p, config: config).remotes()
        out.success(name, remotes) {
            remotes.isEmpty ? "No remotes. Add one with `gitbar remote set <url>`." : remotes.map { "\($0.name)\t\($0.url)" }.joined(separator: "\n")
        }

    case "remote set":
        let p = try project()
        let remotes = try Repo(project: p, config: config).setRemote(url: inv.arguments[0], name: inv.value("--name"))
        out.success(name, remotes) { remotes.map { "\($0.name)\t\($0.url)" }.joined(separator: "\n") }

    case "config show":
        out.success(name, config) { Output.encode(config) }

    case "config get":
        let v = try config.value(forKey: inv.arguments[0])
        out.success(name, [inv.arguments[0]: v]) { v }

    case "config set":
        let key = inv.arguments[0]
        let updated = try ConfigStore.update { try $0.setValue(inv.arguments[1], forKey: key) }
        let v = try updated.value(forKey: key)
        out.success(name, [key: v]) { "\(key) = \(v)" }

    case "config path":
        let paths = ["config": ConfigStore.configURL.path, "activity": ConfigStore.activityURL.path]
        out.success(name, paths) { "config:   \(paths["config"]!)\nactivity: \(paths["activity"]!)" }

    case "activity":
        let limitRaw = inv.value("--limit") ?? "20"
        guard let limit = Int(limitRaw), limit > 0 else { throw GitBarError.usage("--limit must be a positive integer.") }
        let filter = try inv.value("--project").map { try Projects.lookup($0, config: config).name }
        let entries = ActivityLog.recent(limit: limit, project: filter)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        out.success(name, entries) {
            entries.isEmpty ? "No activity yet." : entries.map {
                "\(fmt.string(from: $0.date))  \($0.ok ? "ok " : "ERR")  \($0.source.padding(toLength: 3, withPad: " ", startingAt: 0))  \($0.project)  \($0.action): \($0.summary)"
            }.joined(separator: "\n")
        }

    case "app status":
        let s = appState()
        out.success(name, s) {
            s.running ? "GitBar is running (pid \(s.pid!))." : (s.bundlePath == nil ? "GitBar.app is not installed." : "GitBar is not running.")
        }

    case "app open":
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", GitBarInfo.bundleIdentifier]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw GitBarError(code: "app_not_found", message: "GitBar.app is not installed.",
                              hint: "Run ./build.sh --install from the GitBar source folder.")
        }
        out.success(name, ["launched": true]) { "GitBar launched." }

    case "app quit":
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: GitBarInfo.bundleIdentifier)
        apps.forEach { $0.terminate() }
        out.success(name, ["quit": !apps.isEmpty]) { apps.isEmpty ? "GitBar was not running." : "GitBar quit." }

    default:
        throw GitBarError.usage("Unhandled command '\(name)'.")
    }
}

// MARK: Entry point

let argv = Array(CommandLine.arguments.dropFirst())
let wantsJSON = argv.contains("--json") || ProcessInfo.processInfo.environment["GITBAR_JSON"] == "1"
var commandName = argv.first { !$0.hasPrefix("-") } ?? "help"
do {
    let inv = try Parser.parse(argv)
    commandName = inv.command.name
    try run(inv, Output(json: inv.json))
    exit(0)
} catch let e as GitBarError {
    Output(json: wantsJSON).failure(commandName, e)
    exit(e.exitCode)
} catch {
    let e = GitBarError(code: "error", message: error.localizedDescription)
    Output(json: wantsJSON).failure(commandName, e)
    exit(e.exitCode)
}
