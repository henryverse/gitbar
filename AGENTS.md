# Agent guide: installing and operating GitBar

GitBar is a macOS menu bar app with a `gitbar` CLI for committing, pushing and pulling GitHub projects. This file tells an agent how to install it for a user and drive it safely.

## 1. Install (one time)

Requirements: macOS 14 or later, and the Xcode command line tools (`xcode-select -p` succeeds; if it doesn't, ask the user to run `xcode-select --install`).

```bash
git clone https://github.com/henryverse/gitbar.git ~/Desktop/GitBar   # or wherever the user wants it
cd ~/Desktop/GitBar
./build.sh --install
```

`./build.sh --install` builds the app, copies `GitBar.app` to `~/Applications`, links the CLI to `~/.local/bin/gitbar` and launches the app. If `~/.local/bin` isn't on PATH, add it:

```bash
grep -q '.local/bin' ~/.zshrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Verify:

```bash
~/.local/bin/gitbar app status --json     # result.running == true
~/.local/bin/gitbar help --json           # full machine-readable spec
```

To update later, run `git pull && ./build.sh --install`.

## 2. GitHub access (the user does this)

GitBar uses the user's normal git credentials and **never prompts**. If credentials are missing, network commands fail with exit code 6 (`auth_failed`). Don't try to enter passwords or tokens. Ask the user to do one of these:

- `brew install gh && gh auth login` (HTTPS), or
- create an SSH key and add its `.pub` file at https://github.com/settings/keys

If `gitbar commit` fails with exit code 10 (`identity_missing`), ask the user what name and email to use, then run `git config --global user.name …` and `git config --global user.email …`.

## 3. Register the user's project

```bash
gitbar project add ~/path/to/project --use     # add --init if it isn't a git repository yet
gitbar remote set git@github.com:OWNER/REPO.git   # only if `gitbar remote` lists nothing
gitbar status --json
```

The project you `--use` is the one shown in the menu bar. The app picks up config changes within `refreshInterval` seconds.

## 4. Daily operation

| Goal | Command |
|---|---|
| See state | `gitbar status --json` (add `--fetch` for fresh ahead/behind counts) |
| Commit everything | `gitbar commit -m "message" --json` |
| Push / pull | `gitbar push --json` / `gitbar pull --json` |
| All of it | `gitbar sync -m "message" --json` (commit → pull --rebase → push) |
| What happened | `gitbar activity --json` (includes actions the user took in the app) |

Always pass `--json`. Each call prints one envelope: `{"ok": true, "result": …}` or `{"ok": false, "error": {"code", "message", "hint"}}`.

## 5. Handling errors

| Exit | code | What to do |
|---|---|---|
| 5 | `nothing_to_commit` | Not a problem. Continue with push or pull if needed. |
| 6 | `auth_failed` | Stop and ask the user to set up GitHub access (section 2). |
| 7 | `push_rejected` | Run `gitbar pull --strategy rebase`, then push again, or use `gitbar sync`. |
| 8 | `conflict` | `gitbar status --json` shows `inProgress` and the files with `kind: "conflicted"`. Resolve them if you're confident; otherwise run `gitbar abort` and tell the user. |
| 9 | `no_remote` | Ask the user for the GitHub URL, then run `gitbar remote set <url>`. |
| 10 | `identity_missing` | See section 2. |

Never use `--force-with-lease` unless the user explicitly asks to overwrite the remote branch.
