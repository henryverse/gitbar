import GitBarCore
import SwiftUI

@main
struct GitBarApp: App {
    @StateObject private var model = AppModel()

    init() { Snapshot.runIfRequested() }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let symbol = model.busy != nil ? "arrow.triangle.2.circlepath"
            : (model.status?.conflicted == true || model.statusError != nil) ? "exclamationmark.triangle"
            : "arrow.triangle.branch"
        HStack(spacing: 2) {
            Image(systemName: symbol)
            if model.changeCount > 0 { Text("\(model.changeCount)") }
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if model.config.projects.isEmpty {
                emptyState
            } else if let error = model.statusError {
                errorCard(error)
            } else if let st = model.status {
                statusCard(st)
                changesList(st)
                actions(st)
            } else {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20)
            }
            if let banner = model.banner { bannerView(banner) }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.reloadConfig(); model.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.config.projects, id: \.self) { p in
                    Button {
                        model.select(p)
                    } label: {
                        if p == model.project { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
                Divider()
                Button("Add Project…") { model.addProject() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(model.project?.name ?? "No Project").fontWeight(.semibold).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).monospacedDigit().lineLimit(1).foregroundStyle(.secondary)
            }

            Button { model.refresh(fetch: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Fetch from GitHub and refresh")
                .disabled(model.project == nil || model.busy != nil)

            Menu {
                Button("Add Project…") { model.addProject() }
                Button("Remove \(model.project?.name ?? "Project")") { model.removeCurrent() }
                    .disabled(model.project == nil)
                Divider()
                Button("Set GitHub Remote…") { model.setRemote() }.disabled(model.project == nil)
                Button("Open on GitHub") { model.openOnGitHub() }.disabled(model.status?.remoteURL == nil)
                Button("Show in Finder") { model.openInFinder() }.disabled(model.project == nil)
                Button("Open in Terminal") { model.openInTerminal() }.disabled(model.project == nil)
                Divider()
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { _ in model.toggleLaunchAtLogin() }))
                Divider()
                Button("Quit GitBar") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Add a project folder to get started.").foregroundStyle(.secondary)
            Button("Add Project…") { model.addProject() }.buttonStyle(.borderedProminent)
            Text("Or from a terminal: gitbar project add <path>")
                .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func errorCard(_ e: GitBarError) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(e.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            if let hint = e.hint { Text(hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    // MARK: Status

    private func statusCard(_ st: RepoStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(st.branch ?? (st.inProgress != nil ? "(\(st.inProgress!))" : "detached HEAD")).fontWeight(.medium)
                if let up = st.upstream {
                    Text("→ \(up)").foregroundStyle(.secondary)
                } else if st.branch != nil {
                    Text("not pushed yet").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if st.ahead > 0 { pill("↑\(st.ahead)", .blue, help: "\(st.ahead) commit(s) to push") }
                if st.behind > 0 { pill("↓\(st.behind)", .purple, help: "\(st.behind) commit(s) to pull") }
            }
            if let op = st.inProgress {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(op.capitalized) stopped on conflicts").font(.callout)
                    Spacer()
                    Button("Abort \(op.capitalized)") { model.abort() }.disabled(model.busy != nil)
                }
                .padding(6)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                if let url = st.remoteURL {
                    Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Button("Set GitHub remote…") { model.setRemote() }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func pill(_ text: String, _ color: Color, help: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help(help)
    }

    private func changesList(_ st: RepoStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(st.clean ? "No local changes" : "\(st.changes.count) changed file\(st.changes.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            if !st.clean {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(st.changes, id: \.self) { c in
                            HStack(spacing: 6) {
                                Text(tag(c.kind))
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(color(c.kind))
                                    .frame(width: 12)
                                Text(c.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: min(CGFloat(st.changes.count) * 18 + 4, 150))
            }
        }
    }

    private func tag(_ kind: String) -> String {
        ["added": "A", "deleted": "D", "renamed": "R", "copied": "C", "typechange": "T",
         "untracked": "?", "conflicted": "U"][kind] ?? "M"
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "added", "untracked": return .green
        case "deleted": return .red
        case "conflicted": return .orange
        case "renamed", "copied": return .blue
        default: return .yellow
        }
    }

    // MARK: Actions

    private func actions(_ st: RepoStatus) -> some View {
        let idle = model.busy == nil
        return VStack(spacing: 8) {
            TextField("Commit message (optional)", text: $model.commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($messageFocused)
                .onSubmit { if !st.clean { model.commit() } }
                .disabled(st.clean || !idle)

            HStack(spacing: 8) {
                Button { model.commit() } label: { Label("Commit", systemImage: "checkmark.circle") }
                    .disabled(st.clean || !idle)
                    .help("Stage all changes and commit")
                Button { model.pull() } label: { Label("Pull", systemImage: "arrow.down.circle") }
                    .disabled(!idle || st.remotes.isEmpty)
                    .help("Pull from GitHub")
                Button { model.push() } label: { Label("Push", systemImage: "arrow.up.circle") }
                    .disabled(!idle || st.remotes.isEmpty || !st.hasCommits)
                    .help("Push to GitHub")
                Spacer()
                Button { model.sync() } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!idle || st.remotes.isEmpty || (st.clean && !st.hasCommits))
                    .help("Commit (if needed), pull, then push")
            }
            .controlSize(.regular)
        }
    }

    private func bannerView(_ b: Banner) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: b.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(b.ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let hint = b.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { model.banner = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(8)
        .background((b.ok ? Color.green : Color.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
