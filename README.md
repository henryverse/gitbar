# GitBar

A macOS menu bar app for committing, pushing and pulling a project to and from GitHub, plus a `gitbar` CLI that does the same things, built so an agent can drive it.

## Install

Requires macOS 14+ and the Xcode command line tools. Agents: follow [AGENTS.md](AGENTS.md).

```bash
git clone https://github.com/henryverse/gitbar.git && cd gitbar
./build.sh --install
```

This builds `dist/GitBar.app`, copies it to `~/Applications`, links the CLI to `~/.local/bin/gitbar` and launches the app. Run `./build.sh` on its own to build without installing.

GitBar uses your normal git credentials. If `git push` works in Terminal, GitBar works too. Otherwise set up access once, either with `gh auth login` or by adding an SSH key to GitHub. Git never prompts from GitBar, so missing credentials fail right away with `auth_failed` and never hang.

## Menu bar app

Click the branch icon in the menu bar. The number next to it is how many files have changed.

- **Project picker**: switch projects or add a folder. A folder that isn't a repository yet gets `git init`.
- **Status**: the branch, its upstream, ↑ commits to push and ↓ commits to pull, the remote URL, and the changed files.
- **Commit**: stages everything and commits. If you leave the message empty, GitBar writes one from the changed file names.
- **Pull / Push**: the first push sets the upstream.
- **Sync**: commit if there are changes, then pull (rebase), then push.
- **⋯ menu**: Set GitHub Remote…, Open on GitHub, Show in Finder, Open in Terminal, Launch at Login, Quit.
- If a pull stops on conflicts, an **Abort** button appears.

The app re-reads its config every few seconds (`refreshInterval`), so changes you make with the CLI show up in the app.

## CLI

```
gitbar status [--fetch]                 branch, ahead/behind, changed files
gitbar commit [-m msg] [--all|--no-add]
gitbar push [--remote r] [--force-with-lease]
gitbar pull [--strategy ff-only|rebase|merge]
gitbar sync [-m msg] [--strategy s]     commit (if needed) → pull → push
gitbar abort                            undo a rebase/merge stopped on conflicts
gitbar project list|add <path> [--use] [--init] [--name n]|remove <p>|use <p>|current
gitbar remote [show] | remote set <url> [--name origin]
gitbar config show|get <key>|set <key> <value>|path
gitbar activity [--limit n]             log of what the app and CLI did
gitbar app status|open|quit
gitbar help [command] [--json]
```

Every command that works on a repository accepts `-p/--project <name|path>`. Without it, GitBar uses `$GITBAR_PROJECT`, then the current project (the one shown in the menu bar), then the only registered project.

### For agents

- **`--json`**, or `GITBAR_JSON=1`, prints one JSON document on stdout:
  `{"ok":true,"command":"push","result":{…}}` or
  `{"ok":false,"command":"push","error":{"code":"push_rejected","message":"…","hint":"…","stderr":"…"}}`.
- **`gitbar help --json`** prints the full spec: commands, options, which commands change state, config keys, exit codes and environment variables.
- **Stable exit codes**:

  | Code | Meaning |
  |---|---|
  | 0 | success |
  | 1 | other git failure |
  | 2 | usage error |
  | 3 | no project, project not found, duplicate project, invalid config |
  | 4 | not a repository |
  | 5 | nothing to commit or abort |
  | 6 | auth failed |
  | 7 | push rejected (pull first) |
  | 8 | conflict, or branches diverged |
  | 9 | no remote, no upstream, detached HEAD, no commits |
  | 10 | git identity not set |

- **Never interactive**: no prompts or editors, and SSH runs in batch mode.
- **Recovery**: on a conflict (exit 8), check `status --json` (`inProgress: "rebase"` and files with `kind: "conflicted"`), then either resolve them or run `gitbar abort`.
- **Typical loop**:
  ```bash
  gitbar project add ~/code/site --use
  gitbar remote set git@github.com:me/site.git
  gitbar sync -m "Update docs" --json
  ```

### Config keys

| Key | Default | |
|---|---|---|
| `defaultRemote` | `origin` | remote used when the branch has no upstream |
| `pullStrategy` | `ff-only` | how `pull` integrates remote changes |
| `syncPullStrategy` | `rebase` | how `sync` integrates remote changes |
| `stageAll` | `true` | `git add -A` before committing |
| `refreshInterval` | `5` | seconds between the app's status refreshes |
| `gitPath` | `/usr/bin/git` | git executable |

The config file is `~/Library/Application Support/GitBar/config.json`, next to `activity.jsonl`. Override the directory with `GITBAR_HOME`.

## Layout

- `Sources/GitBarCore`: config, project registry, git operations and error classification, shared by the app and the CLI
- `Sources/gitbar`: the CLI
- `Sources/GitBarApp`: the SwiftUI menu bar app (`GitBar --snapshot out.png` renders the panel to a PNG for layout checks)
- `build.sh`: packages `GitBar.app`, with the CLI at `Contents/Helpers/gitbar`
