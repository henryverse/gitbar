import Foundation
import GitBarCore

struct OptionSpec: Encodable {
    let name: String
    let short: String?
    let value: String?
    let description: String

    init(_ name: String, short: String? = nil, value: String? = nil, _ description: String) {
        self.name = name
        self.short = short
        self.value = value
        self.description = description
    }
}

struct CommandSpec: Encodable {
    let name: String
    let arguments: [String]
    let summary: String
    let mutates: Bool
    let options: [OptionSpec]

    var usage: String {
        var parts = ["gitbar", name] + arguments
        for o in options {
            let flag = o.short ?? o.name
            parts.append(o.value.map { "[\(flag) <\($0)>]" } ?? "[\(flag)]")
        }
        return parts.joined(separator: " ")
    }
}

enum Opt {
    static let project = OptionSpec("--project", short: "-p", value: "name|path",
                                    "Target project (default: $GITBAR_PROJECT, then the current project).")
    static let message = OptionSpec("--message", short: "-m", value: "text",
                                    "Commit message (default: generated from changed file names).")
    static let all = OptionSpec("--all", short: "-a", "Stage all changes first (default when stageAll=true).")
    static let noAdd = OptionSpec("--no-add", "Commit only what is already staged.")
    static let remote = OptionSpec("--remote", value: "name", "Remote to use instead of upstream/defaultRemote.")
    static let strategy = OptionSpec("--strategy", value: "ff-only|rebase|merge", "How to integrate remote changes.")
}

let commands: [CommandSpec] = [
    CommandSpec(name: "status", arguments: [], summary: "Show branch, ahead/behind counts and changed files.", mutates: false,
                options: [Opt.project, OptionSpec("--fetch", "Fetch from the remote first so ahead/behind is current.")]),
    CommandSpec(name: "commit", arguments: [], summary: "Stage and commit changes.", mutates: true,
                options: [Opt.project, Opt.message, Opt.all, Opt.noAdd]),
    CommandSpec(name: "push", arguments: [], summary: "Push the current branch to GitHub (sets upstream on first push).", mutates: true,
                options: [Opt.project, Opt.remote,
                          OptionSpec("--force-with-lease", "Overwrite the remote branch if nobody else pushed to it.")]),
    CommandSpec(name: "pull", arguments: [], summary: "Pull the current branch from GitHub.", mutates: true,
                options: [Opt.project, Opt.remote, Opt.strategy]),
    CommandSpec(name: "sync", arguments: [], summary: "Commit (if needed), pull, then push.", mutates: true,
                options: [Opt.project, Opt.message, Opt.noAdd, Opt.strategy]),
    CommandSpec(name: "abort", arguments: [], summary: "Abort a rebase/merge that stopped on conflicts.", mutates: true,
                options: [Opt.project]),
    CommandSpec(name: "project list", arguments: [], summary: "List registered projects.", mutates: false, options: []),
    CommandSpec(name: "project add", arguments: ["<path>"], summary: "Register a local repository.", mutates: true,
                options: [OptionSpec("--name", value: "name", "Display name (default: folder name)."),
                          OptionSpec("--use", "Also make it the current project."),
                          OptionSpec("--init", "Run `git init` if the folder is not a repository.")]),
    CommandSpec(name: "project remove", arguments: ["<name|path>"], summary: "Unregister a project (files are untouched).", mutates: true, options: []),
    CommandSpec(name: "project use", arguments: ["<name|path>"], summary: "Set the current project shown in the menu bar.", mutates: true, options: []),
    CommandSpec(name: "project current", arguments: [], summary: "Print the current project.", mutates: false, options: [Opt.project]),
    CommandSpec(name: "remote show", arguments: [], summary: "List the project's remotes.", mutates: false, options: [Opt.project]),
    CommandSpec(name: "remote set", arguments: ["<url>"], summary: "Add or update a remote (default: defaultRemote).", mutates: true,
                options: [Opt.project, OptionSpec("--name", value: "remote", "Remote name.")]),
    CommandSpec(name: "config show", arguments: [], summary: "Print the full configuration.", mutates: false, options: []),
    CommandSpec(name: "config get", arguments: ["<key>"], summary: "Print one setting.", mutates: false, options: []),
    CommandSpec(name: "config set", arguments: ["<key>", "<value>"], summary: "Change one setting.", mutates: true, options: []),
    CommandSpec(name: "config path", arguments: [], summary: "Print where the config and activity log live.", mutates: false, options: []),
    CommandSpec(name: "activity", arguments: [], summary: "Show recent commits/pushes/pulls made by the app or CLI.", mutates: false,
                options: [OptionSpec("--limit", value: "n", "Number of entries (default 20)."),
                          OptionSpec("--project", short: "-p", value: "name", "Only this project.")]),
    CommandSpec(name: "app status", arguments: [], summary: "Report whether the menu bar app is running.", mutates: false, options: []),
    CommandSpec(name: "app open", arguments: [], summary: "Launch the menu bar app.", mutates: true, options: []),
    CommandSpec(name: "app quit", arguments: [], summary: "Quit the menu bar app.", mutates: true, options: []),
    CommandSpec(name: "version", arguments: [], summary: "Print the version.", mutates: false, options: []),
    CommandSpec(name: "help", arguments: ["[command]"], summary: "Show help (add --json for a machine-readable spec).", mutates: false, options: []),
]

/// Bare group names run a default subcommand.
let groupDefaults = ["project": "project list", "remote": "remote show", "config": "config show", "app": "app status"]

let globalOptions = [
    OptionSpec("--json", "Emit a JSON envelope on stdout: {ok, command, result | error}. Also enabled by GITBAR_JSON=1."),
    OptionSpec("--help", short: "-h", "Show help for the command."),
]

struct Invocation {
    var command: CommandSpec
    var arguments: [String]
    var values: [String: String]
    var flags: Set<String>
    var json: Bool
    var help: Bool

    func value(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }
}

enum Parser {
    static func parse(_ argv: [String]) throws -> Invocation {
        let all = commands.flatMap(\.options) + globalOptions
        var byFlag: [String: OptionSpec] = [:]
        for o in all {
            byFlag[o.name] = o
            if let s = o.short { byFlag[s] = o }
        }

        var positionals: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var i = 0, endOfOptions = false
        while i < argv.count {
            let arg = argv[i]
            i += 1
            if endOfOptions || !arg.hasPrefix("-") || arg == "-" { positionals.append(arg); continue }
            if arg == "--" { endOfOptions = true; continue }
            var key = arg, inline: String?
            if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                key = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }
            if key == "--version" { flags.insert("--version"); continue }
            guard let spec = byFlag[key] else { throw GitBarError.usage("Unknown option '\(key)'.") }
            if spec.value != nil {
                if let inline { values[spec.name] = inline; continue }
                guard i < argv.count else { throw GitBarError.usage("Option \(key) needs a value (<\(spec.value!)>).") }
                values[spec.name] = argv[i]
                i += 1
            } else {
                if inline != nil { throw GitBarError.usage("Option \(key) does not take a value.") }
                flags.insert(spec.name)
            }
        }

        let json = flags.contains("--json") || ProcessInfo.processInfo.environment["GITBAR_JSON"] == "1"
        let help = flags.contains("--help")

        if flags.contains("--version") && positionals.isEmpty { positionals = ["version"] }
        if positionals.isEmpty { positionals = ["help"] }

        var command: CommandSpec?
        var rest: [String] = []
        if positionals.count >= 2, let c = commands.first(where: { $0.name == "\(positionals[0]) \(positionals[1])" }) {
            command = c
            rest = Array(positionals.dropFirst(2))
        } else if let c = commands.first(where: { $0.name == positionals[0] }) {
            command = c
            rest = Array(positionals.dropFirst())
        } else if let def = groupDefaults[positionals[0]] {
            if positionals.count > 1 {
                let subs = commands.filter { $0.name.hasPrefix(positionals[0] + " ") }.map { $0.name.split(separator: " ")[1] }
                throw GitBarError.usage("Unknown subcommand '\(positionals[1])' for \(positionals[0]).",
                                               hint: "Available: " + subs.joined(separator: ", "))
            }
            command = commands.first { $0.name == def }
        }
        guard let command else {
            throw GitBarError.usage("Unknown command '\(positionals[0])'.")
        }

        if !help {
            let allowed = Set(command.options.map(\.name) + globalOptions.map(\.name) + ["--version"])
            for name in Array(values.keys) + Array(flags) where !allowed.contains(name) {
                throw GitBarError.usage("Option \(name) is not valid for `gitbar \(command.name)`.",
                                               hint: "Usage: \(command.usage)")
            }
            let required = command.arguments.filter { $0.hasPrefix("<") }.count
            let maxArgs = command.arguments.count
            if rest.count < required || rest.count > maxArgs {
                throw GitBarError.usage("Wrong number of arguments for `gitbar \(command.name)`.",
                                               hint: "Usage: \(command.usage)")
            }
        }
        return Invocation(command: command, arguments: rest, values: values, flags: flags, json: json, help: help)
    }
}
