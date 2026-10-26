# Mac mini: the always-on factory host

Set up 2026-10-26. The mini runs the dispatcher every 30 minutes as a dedicated, non-admin macOS user. Nothing on it but what the factory needs.

## Users

| User | Role |
|---|---|
| `factory` (uid 501, admin) | Admin only: `sudo` for power, sharing, Tailscale, FileVault. Owns nothing the factory runs. |
| `softwarefactory` (uid 502, not admin) | Runs everything: clones, logins, LaunchAgent, workers. Owns `/opt/homebrew` (`sudo chown -R softwarefactory:admin /opt/homebrew` once, as `factory`). |

## Pinned tooling (as installed)

| Tool | Version | Source |
|---|---|---|
| macOS | 27.0 (26A425), arm64 | |
| Xcode Command Line Tools | present at `/Library/Developer/CommandLineTools` | Apple |
| Homebrew | 7.0.11 | `/opt/homebrew` |
| fnm | 1.39.0 | `brew install fnm` |
| node / npm | 24.22.1 / 11.19.1 | `fnm install 24 && fnm default 24` |
| gh | 2.103.2 | `brew install gh` |
| jq | 1.7.1 | macOS built-in (`/usr/bin/jq`) |
| keycard | 0.0.38 | `brew install --cask keycardai/tap/keycard` (binary cask, no admin) |
| claude | 2.1.310 | native installer in `~/.local/bin`; self-updates in `~/.local/share/claude/versions` |
| Claude Code plugin `linear@claude-plugins-official` | 58267944f921 | `claude plugin install linear@claude-plugins-official` |

`~/.zshrc` and `~/.zprofile` put `/opt/homebrew/bin` on PATH and run `fnm env --use-on-cd`. Launchd does not read either, so the plist carries its own PATH (below). Codex is not installed; the judge runs in GitHub Actions.

## Layout

| Path | What |
|---|---|
| `~/Documents/Development/factory` | this plugin (`--plugin-dir`) |
| `~/Documents/Development/plan-my-today` | pilot repo; worktrees land beside it as `plan-my-today-factory-<ID>` |
| `~/.factory/registry.json` | `{"P-KIM-206": "/Users/softwarefactory/Documents/Development/plan-my-today"}` |
| `~/.factory/logs/dispatch.log`, `dispatch.err.log` | LaunchAgent stdout / stderr, one `=== <UTC> sweep start/exit` pair per sweep |
| `~/.factory/logs/<ID>.log` | one worker run |
| `~/Library/LaunchAgents/ai.keycard.factory.dispatch.plist` | the dispatcher (from `templates/`) |

## Logins (all in the softwarefactory login keychain)

| Session | How it was created | Check |
|---|---|---|
| Claude Code | claude.ai device/browser login (Keycard enterprise org, as Kim) | `claude auth status` |
| Keycard | `keycard auth signin --device --org p48htojvia150hqw8n22g00d4i --zone 1jgewf106fax3oaf70vyykwj2i` (two codes: org, then zone), then `keycard auth resource urn:github:factory --zone 1jgewf106fax3oaf70vyykwj2i` | `keycard credential read --zone 1jgewf106fax3oaf70vyykwj2i urn:github:factory` |
| GitHub (Kim, for cloning the private plugin repo and this PR) | `gh auth login -h github.com -p https -w` | `gh auth status` |
| Linear MCP | the claude.ai Linear connector comes with the Claude login and is already connected; the plugin's own server (`plugin:linear:linear`) is a one-time browser OAuth from an interactive `claude` session via `/mcp` | `claude mcp list \| grep -i linear` |

Workers never hold a GitHub token: `keycard agent exec --config keycard.toml` brokers it in as `GH_TOKEN`. Verified on the mini:

```bash
cd ~/Documents/Development/factory
keycard agent exec --config keycard.toml --zone 1jgewf106fax3oaf70vyykwj2i -- gh api user --jq .login   # kmaida
keycard agent exec --config keycard.toml --zone 1jgewf106fax3oaf70vyykwj2i -- gh api -X POST \
  repos/kmaida/plan-my-today/statuses/$(git -C ~/Documents/Development/plan-my-today rev-parse origin/main) \
  -f state=success -f context=factory/judge-claude                                                      # HTTP 403
```

## The LaunchAgent

`templates/ai.keycard.factory.dispatch.plist` runs `claude -p "/factory:factory-dispatch" --permission-mode bypassPermissions` with `KEYCARD_ZONE` set, every 1800 s and once at load. Install or update:

```bash
sed "s|__HOME__|$HOME|g" ~/Documents/Development/factory/templates/ai.keycard.factory.dispatch.plist \
  > ~/Library/LaunchAgents/ai.keycard.factory.dispatch.plist
launchctl bootout gui/$(id -u)/ai.keycard.factory.dispatch 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.keycard.factory.dispatch.plist
launchctl print gui/$(id -u)/ai.keycard.factory.dispatch | grep -E 'state|last exit'
tail -f ~/.factory/logs/dispatch.log
```

Fire one sweep now: `launchctl kickstart gui/$(id -u)/ai.keycard.factory.dispatch`. Stop the schedule: `launchctl bootout gui/$(id -u)/ai.keycard.factory.dispatch` (the repo-level pause is `gh variable set FACTORY_PAUSED -b true -R kmaida/plan-my-today`). By hand, from a terminal, never from inside a Claude session:

```bash
KEYCARD_ZONE=1jgewf106fax3oaf70vyykwj2i claude -p "/factory:factory-dispatch" --plugin-dir ~/Documents/Development/factory --permission-mode bypassPermissions
```

A LaunchAgent lives in the user's GUI session: it starts when `softwarefactory` logs in, which automatic login does at every boot (next section).

## Always-on (admin, as `factory`)

```bash
sudo pmset -a sleep 0 disksleep 0 autorestart 1
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
sudo systemsetup -setremotelogin on
```

Screen Sharing and Automatic login are System Settings switches (General → Sharing; Users & Groups → Automatic login). Tailscale is the standalone app from tailscale.com installed into `/Applications` as admin, signed in to Kim's free tailnet, with its network extension approved. The VPN is a system extension that launchd runs at the system level, so it is up after boot without the menu bar app or a logged-in user. Machine name `kims-mac-mini` (`kims-mac-mini.tailcd6b2c.ts.net`, 100.83.157.111). Reach it with `ssh softwarefactory@kims-mac-mini` once Remote Login is on, or Screen Sharing to the same name.

**FileVault tradeoff.** The Claude, Keycard and GitHub sessions are in the login keychain, which opens only when `softwarefactory` logs in. After a power cut or `autorestart`, a machine with FileVault on stops at the pre-boot unlock screen and nothing runs until someone types a password (over Screen Sharing is not possible before unlock). Automatic login is the fix, and macOS refuses it while FileVault is on. So the choice is: FileVault on and a reboot needs a human at the console, or FileVault off, automatic login as `softwarefactory`, and the factory survives reboots on its own. The disk then holds no secrets at rest beyond the keychain, which stays encrypted with the account password either way. Decision 2026-10-26: FileVault off, automatic login as `softwarefactory`, 5-minute screen lock. The mini sits in Kim's home; every session on it is revocable from the web (GitHub token, Keycard session, claude.ai).
