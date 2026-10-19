import AppKit
import GitBarCore
import ServiceManagement
import SwiftUI

struct Banner: Equatable {
    let ok: Bool
    let message: String
    let hint: String?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config = Config()
    @Published private(set) var status: RepoStatus?
    @Published private(set) var statusError: GitBarError?
    @Published private(set) var busy: String?
    @Published var banner: Banner?
    @Published var commitMessage = ""
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var configDate: Date?
    private var timer: Timer?
    private var timerInterval: Int = 0
    private var refreshing = false

    init() {
        reloadConfig(force: true)
        refresh()
    }

    var project: Project? { try? Projects.resolve(nil, config: config) }
    var changeCount: Int { status?.changes.count ?? 0 }
    var canSync: Bool { project != nil && busy == nil && statusError == nil }

    // MARK: Config & status

    func reloadConfig(force: Bool = false) {
        let date = ConfigStore.modificationDate()
        guard force || date != configDate else { return }
        configDate = date
        do {
            let new = try ConfigStore.load()
            let projectChanged = new.currentProject != config.currentProject || new.projects != config.projects
            config = new
            if projectChanged { status = nil; statusError = nil; banner = nil }
        } catch let e as GitBarError {
            statusError = e
        } catch {}
        scheduleTimer()
    }

    private func scheduleTimer() {
        let interval = max(2, config.refreshInterval)
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        reloadConfig()
        if busy == nil { refresh() }
    }

    func refresh(fetch: Bool = false) {
        guard let project else { status = nil; statusError = nil; return }
        guard !refreshing else { return }
        refreshing = true
        if fetch { busy = "Fetching…" }
        let config = self.config
        Task.detached {
            let result = Result { try Repo(project: project, config: config).status(fetch: fetch) }
            await MainActor.run {
                self.refreshing = false
                if fetch { self.busy = nil }
                guard self.project == project else { return }
                switch result {
                case .success(let st): self.status = st; self.statusError = nil
                case .failure(let e as GitBarError):
                    if fetch { self.banner = Banner(ok: false, message: e.message, hint: e.hint) }
                    else { self.statusError = e }
                case .failure(let e): self.statusError = GitBarError(code: "error", message: e.localizedDescription)
                }
            }
        }
    }

    // MARK: Git actions

    func commit() {
        let message = commitMessage
        perform("commit", "Committing…") { repo, _ in try repo.commit(message: message).summary }
    }

    func push() { perform("push", "Pushing…") { try $0.push(progress: $1).summary } }
    func pull() { perform("pull", "Pulling…") { try $0.pull(progress: $1).summary } }
    func abort() { perform("abort", "Aborting…") { repo, _ in "Aborted \(try repo.abort().aborted)." } }

    func sync() {
        let message = commitMessage
        perform("sync", "Syncing…") { try $0.sync(message: message, progress: $1).summary }
    }

    private func perform(_ action: String, _ label: String,
                         _ op: @escaping @Sendable (Repo, @escaping ProgressHandler) throws -> String) {
        guard let project, busy == nil else { return }
        busy = label
        banner = nil
        let config = self.config
        Task.detached {
            let repo = Repo(project: project, config: config)
            let outcome: Result<String, GitBarError>
            // Main queue (not a Task) so updates stay in order and land before the completion below.
            let progress: ProgressHandler = { p in
                DispatchQueue.main.async { MainActor.assumeIsolated { if self.busy != nil { self.busy = p.summary } } }
            }
            do { outcome = .success(try op(repo, progress)) }
            catch let e as GitBarError { outcome = .failure(e) }
            catch { outcome = .failure(GitBarError(code: "error", message: error.localizedDescription)) }
            switch outcome {
            case .success(let s):
                ActivityLog.append(ActivityEntry(source: "app", project: project.name, action: action, ok: true, summary: s))
            case .failure(let e):
                ActivityLog.append(ActivityEntry(source: "app", project: project.name, action: action, ok: false,
                                                 summary: e.message, errorCode: e.code))
            }
            await MainActor.run {
                self.busy = nil
                switch outcome {
                case .success(let s):
                    self.banner = Banner(ok: true, message: s, hint: nil)
                    if action == "commit" || action == "sync" { self.commitMessage = "" }
                case .failure(let e):
                    self.banner = Banner(ok: false, message: e.message, hint: e.hint)
                }
                self.refresh()
            }
        }
    }

    // MARK: Projects

    func select(_ project: Project) {
        apply { try Projects.use(project.name) }
    }

    func addProject() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a project folder. If it isn't a git repository yet, GitBar will initialize one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        apply { try Projects.add(path: url.path, makeCurrent: true, initRepo: true) }
    }

    func removeCurrent() {
        guard let project else { return }
        apply { try Projects.remove(project.name) }
    }

    func setRemote() {
        guard let project else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "GitHub remote for \(project.name)"
        alert.informativeText = "Paste the repository URL, e.g. https://github.com/you/repo.git or git@github.com:you/repo.git"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = status?.remoteURL ?? ""
        field.placeholderString = "https://github.com/owner/repo.git"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        let config = self.config
        do {
            _ = try Repo(project: project, config: config).setRemote(url: url)
            banner = Banner(ok: true, message: "Remote set to \(url)", hint: nil)
        } catch let e as GitBarError {
            banner = Banner(ok: false, message: e.message, hint: e.hint)
        } catch {}
        refresh()
    }

    private func apply(_ body: () throws -> Any) {
        do {
            _ = try body()
            reloadConfig(force: true)
            refresh()
        } catch let e as GitBarError {
            banner = Banner(ok: false, message: e.message, hint: e.hint)
        } catch {
            banner = Banner(ok: false, message: error.localizedDescription, hint: nil)
        }
    }

    // MARK: Misc

    func openInFinder() {
        guard let project else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }

    func openInTerminal() {
        guard let project else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: project.path)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func openOnGitHub() {
        guard let raw = status?.remoteURL, let url = AppModel.webURL(forRemote: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    static func webURL(forRemote remote: String) -> URL? {
        var s = remote
        if s.hasPrefix("git@") {
            s = "https://" + s.dropFirst(4).replacingOccurrences(of: ":", with: "/")
        } else if s.hasPrefix("ssh://git@") {
            s = "https://" + s.dropFirst("ssh://git@".count)
        }
        if s.hasSuffix(".git") { s.removeLast(4) }
        guard s.hasPrefix("http") else { return nil }
        return URL(string: s)
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            banner = Banner(ok: false, message: "Couldn't change Launch at Login: \(error.localizedDescription)",
                            hint: "Move GitBar.app to /Applications or ~/Applications and try again.")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
