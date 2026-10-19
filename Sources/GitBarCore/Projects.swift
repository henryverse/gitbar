import Foundation

public enum Projects {
    /// Resolution order: explicit ref → $GITBAR_PROJECT → config.currentProject → the only project.
    /// A ref may be a registered name or a filesystem path (registered or not).
    public static func resolve(_ ref: String?, config: Config) throws -> Project {
        let env = ProcessInfo.processInfo.environment["GITBAR_PROJECT"].flatMap { $0.isEmpty ? nil : $0 }
        if let ref = ref ?? env { return try lookup(ref, config: config) }
        if let current = config.currentProject, let p = config.projects.first(where: { $0.name == current }) {
            return p
        }
        if config.projects.count == 1 { return config.projects[0] }
        throw GitBarError(code: "no_project",
                          message: config.projects.isEmpty ? "No projects registered." : "No current project selected.",
                          hint: config.projects.isEmpty
                              ? "Add one with `gitbar project add <path>`."
                              : "Pick one with `gitbar project use <name>` or pass `--project <name|path>`.")
    }

    public static func lookup(_ ref: String, config: Config) throws -> Project {
        if let p = config.projects.first(where: { $0.name == ref }) { return p }
        let looksLikePath = ref.contains("/") || ref == "." || ref == ".." || ref.hasPrefix("~")
        if looksLikePath || FileManager.default.fileExists(atPath: ref) {
            let path = normalize(ref)
            let top = (try? GitRunner(config: config).output(["rev-parse", "--show-toplevel"], in: path)) ?? path
            if let p = config.projects.first(where: { $0.path == top || $0.path == path }) { return p }
            return Project(name: (top as NSString).lastPathComponent, path: top)
        }
        throw GitBarError(code: "project_not_found", message: "No project named '\(ref)'.",
                          hint: "Registered: " + (config.projects.isEmpty ? "(none)" : config.projects.map(\.name).joined(separator: ", ")))
    }

    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path
    }

    @discardableResult
    public static func add(path rawPath: String, name: String? = nil, makeCurrent: Bool = false,
                           initRepo: Bool = false) throws -> (project: Project, config: Config) {
        var config = try ConfigStore.load()
        let git = GitRunner(config: config)
        let path = normalize(rawPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw GitBarError(code: "project_not_found", message: "Folder \(path) does not exist.")
        }
        var top = try? git.output(["rev-parse", "--show-toplevel"], in: path)
        if top == nil {
            guard initRepo else {
                throw GitBarError(code: "not_a_repo", message: "\(path) is not a git repository.",
                                  hint: "Pass `--init` to run `git init` there.")
            }
            try git.checked(["init", "-b", "main"], in: path)
            top = try git.output(["rev-parse", "--show-toplevel"], in: path)
        }
        let root = top ?? path
        if let existing = config.projects.first(where: { $0.path == root }) {
            if let name, name != existing.name {
                throw GitBarError(code: "duplicate_project", message: "\(root) is already registered as '\(existing.name)'.")
            }
            if makeCurrent { config.currentProject = existing.name; try ConfigStore.save(config) }
            return (existing, config)
        }
        let base = name ?? (root as NSString).lastPathComponent
        if name != nil, config.projects.contains(where: { $0.name == base }) {
            throw GitBarError(code: "duplicate_project", message: "A project named '\(base)' already exists.")
        }
        var unique = base, n = 2
        while config.projects.contains(where: { $0.name == unique }) { unique = "\(base)-\(n)"; n += 1 }
        let project = Project(name: unique, path: root)
        config.projects.append(project)
        if makeCurrent || config.currentProject == nil { config.currentProject = project.name }
        try ConfigStore.save(config)
        return (project, config)
    }

    @discardableResult
    public static func remove(_ ref: String) throws -> (project: Project, config: Config) {
        var config = try ConfigStore.load()
        let p = try lookup(ref, config: config)
        guard let idx = config.projects.firstIndex(of: p) else {
            throw GitBarError(code: "project_not_found", message: "'\(ref)' is not a registered project.")
        }
        config.projects.remove(at: idx)
        if config.currentProject == p.name { config.currentProject = config.projects.first?.name }
        try ConfigStore.save(config)
        return (p, config)
    }

    @discardableResult
    public static func use(_ ref: String) throws -> (project: Project, config: Config) {
        let config = try ConfigStore.load()
        let p = try lookup(ref, config: config)
        if !config.projects.contains(p) { return try add(path: p.path, makeCurrent: true) }
        var updated = config
        updated.currentProject = p.name
        try ConfigStore.save(updated)
        return (p, updated)
    }
}

public struct ActivityEntry: Codable, Sendable {
    public let date: Date
    public let source: String
    public let project: String
    public let action: String
    public let ok: Bool
    public let summary: String
    public let errorCode: String?

    public init(source: String, project: String, action: String, ok: Bool, summary: String, errorCode: String? = nil) {
        self.date = Date()
        self.source = source
        self.project = project
        self.action = action
        self.ok = ok
        self.summary = summary
        self.errorCode = errorCode
    }
}

/// Append-only JSONL log shared by the app and the CLI, so either side can see what the other did.
public enum ActivityLog {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func append(_ entry: ActivityEntry) {
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        let url = ConfigStore.activityURL
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    public static func recent(limit: Int, project: String? = nil) -> [ActivityEntry] {
        guard let text = try? String(contentsOf: ConfigStore.activityURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = text.split(separator: "\n").compactMap {
            try? decoder.decode(ActivityEntry.self, from: Data($0.utf8))
        }.filter { project == nil || $0.project == project }
        return Array(entries.suffix(limit))
    }
}
