import Foundation

public enum GitBarInfo {
    public static let version = "1.0.0"
    public static let bundleIdentifier = "com.gitbar.app"
}

public enum PullStrategy: String, Codable, CaseIterable, Sendable {
    case ffOnly = "ff-only"
    case rebase
    case merge

    var gitFlags: [String] {
        switch self {
        case .ffOnly: return ["--ff-only"]
        case .rebase: return ["--rebase", "--autostash"]
        case .merge: return ["--no-rebase", "--no-edit"]
        }
    }
}

public struct Project: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Shared by the menu bar app and the CLI. Stored as JSON at `ConfigStore.configURL`;
/// the app picks up changes made by the CLI on its next refresh tick.
public struct Config: Codable, Equatable, Sendable {
    public var projects: [Project] = []
    public var currentProject: String?
    public var defaultRemote: String = "origin"
    public var pullStrategy: PullStrategy = .ffOnly
    public var syncPullStrategy: PullStrategy = .rebase
    public var stageAll: Bool = true
    public var refreshInterval: Int = 5
    public var gitPath: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? d.projects
        currentProject = try c.decodeIfPresent(String.self, forKey: .currentProject)
        defaultRemote = try c.decodeIfPresent(String.self, forKey: .defaultRemote) ?? d.defaultRemote
        pullStrategy = try c.decodeIfPresent(PullStrategy.self, forKey: .pullStrategy) ?? d.pullStrategy
        syncPullStrategy = try c.decodeIfPresent(PullStrategy.self, forKey: .syncPullStrategy) ?? d.syncPullStrategy
        stageAll = try c.decodeIfPresent(Bool.self, forKey: .stageAll) ?? d.stageAll
        refreshInterval = try c.decodeIfPresent(Int.self, forKey: .refreshInterval) ?? d.refreshInterval
        gitPath = try c.decodeIfPresent(String.self, forKey: .gitPath)
    }

    public struct KeyInfo: Codable, Sendable {
        public let key: String
        public let type: String
        public let defaultValue: String
        public let description: String
    }

    public static let settableKeys: [KeyInfo] = [
        KeyInfo(key: "defaultRemote", type: "string", defaultValue: "origin",
                description: "Remote used by push/pull when the branch has no upstream."),
        KeyInfo(key: "pullStrategy", type: "ff-only|rebase|merge", defaultValue: "ff-only",
                description: "How `pull` integrates remote changes."),
        KeyInfo(key: "syncPullStrategy", type: "ff-only|rebase|merge", defaultValue: "rebase",
                description: "How `sync` integrates remote changes after committing."),
        KeyInfo(key: "stageAll", type: "bool", defaultValue: "true",
                description: "Stage every change (git add -A) before committing."),
        KeyInfo(key: "refreshInterval", type: "int (seconds, >= 2)", defaultValue: "5",
                description: "How often the menu bar app re-reads config and repo status."),
        KeyInfo(key: "gitPath", type: "string|unset", defaultValue: "/usr/bin/git",
                description: "Path to the git executable. Set to `unset` to clear."),
    ]

    public func value(forKey key: String) throws -> String {
        switch key {
        case "defaultRemote": return defaultRemote
        case "pullStrategy": return pullStrategy.rawValue
        case "syncPullStrategy": return syncPullStrategy.rawValue
        case "stageAll": return String(stageAll)
        case "refreshInterval": return String(refreshInterval)
        case "gitPath": return gitPath ?? ""
        case "currentProject": return currentProject ?? ""
        default: throw Config.unknownKey(key)
        }
    }

    public mutating func setValue(_ raw: String, forKey key: String) throws {
        let value = raw.trimmingCharacters(in: .whitespaces)
        func bad(_ expected: String) -> GitBarError {
            .usage("Invalid value '\(raw)' for \(key); expected \(expected).")
        }
        switch key {
        case "defaultRemote":
            guard !value.isEmpty else { throw bad("a remote name") }
            defaultRemote = value
        case "pullStrategy", "syncPullStrategy":
            guard let s = PullStrategy(rawValue: value) else { throw bad("ff-only, rebase or merge") }
            if key == "pullStrategy" { pullStrategy = s } else { syncPullStrategy = s }
        case "stageAll":
            switch value.lowercased() {
            case "true", "yes", "1", "on": stageAll = true
            case "false", "no", "0", "off": stageAll = false
            default: throw bad("true or false")
            }
        case "refreshInterval":
            guard let n = Int(value), n >= 2 else { throw bad("an integer >= 2") }
            refreshInterval = n
        case "gitPath":
            gitPath = (value.isEmpty || value == "unset") ? nil : (value as NSString).expandingTildeInPath
        default:
            throw Config.unknownKey(key)
        }
    }

    static func unknownKey(_ key: String) -> GitBarError {
        .usage("Unknown config key '\(key)'.",
               hint: "Valid keys: " + settableKeys.map(\.key).joined(separator: ", "))
    }
}

public enum ConfigStore {
    /// Override with GITBAR_HOME (useful for tests and sandboxed agents).
    public static var directory: URL {
        if let home = ProcessInfo.processInfo.environment["GITBAR_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GitBar", isDirectory: true)
    }

    public static var configURL: URL { directory.appendingPathComponent("config.json") }
    public static var activityURL: URL { directory.appendingPathComponent("activity.jsonl") }

    public static func load() throws -> Config {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw GitBarError(code: "config_invalid",
                              message: "Could not read config at \(url.path): \(error.localizedDescription)",
                              hint: "Fix or delete the file; GitBar recreates it with defaults.")
        }
    }

    public static func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    @discardableResult
    public static func update(_ body: (inout Config) throws -> Void) throws -> Config {
        var config = try load()
        try body(&config)
        try save(config)
        return config
    }

    public static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
    }
}
