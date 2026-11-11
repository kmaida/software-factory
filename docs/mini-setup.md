# Setting up the mini (FileVault on, no auto-login, MDM)

The factory needs a logged-in desktop session, because Docker Desktop only runs inside one. With FileVault on and
auto-login off, unlocking the disk at boot with the account's password logs it straight in. After every boot,
someone types that password once at the keyboard, then locks the screen. A locked screen keeps everything running;
a logout does not.

## The account

The mini has one account and the factory runs under it: the admin user, short name and home folder
`kimmaida-mini`, display name "Software Factory". The FileVault and login screens show the display name; paths and
`ssh` use the short name.

There is no separate non-admin factory user (it was deleted 2026-11-11). Fast user switching never appeared on this
machine, in the menu bar or on the lock screen, although `MultipleSessionEnabled` reads 1, so a second account
could not hold a desktop session, and Docker needs one.

The account is not what isolates the agents. Every step runs in a container with a read-only root, all
capabilities dropped, only the run's own work directories mounted, and egress through a per-step allowlist proxy
(`run_container` in `factory`). What does run as this account is the orchestrator and Docker Desktop, so:

- Never run `factory` with `sudo`.
- `~/factory-secrets` stays mode 700.
- Use the account for the factory and nothing else.

`git config --global user.name` is unset on the mini, on purpose: the factory authors every commit as the GitHub
App's bot. Set it only if you start committing by hand there.

## 1. Machine settings and installs

Power settings (System Settings, Energy, or):

```bash
sudo pmset -a sleep 0 disksleep 0 autorestart 1 womp 1
pmset -g
```

If `pmset -g` shows your values reverted, the MDM profile owns them. Do not rely on this alone: on 2026-11-11 the
mini slept after the night's batch ended and dropped off Tailscale until someone woke it. The README's
`caffeinate -i -w $!` only holds while the batch is running.

What keeps it awake between batches is the Caffeine app, which MDM allows. Set it to activate at launch and to
stay on indefinitely, and add it to Login Items; it only runs inside the logged-in session. To check it is holding:

```bash
pmset -g assertions | grep -iE "caffeine|PreventUserIdleSystemSleep"
```

Ask IT two things:

- Can macOS updates on this machine be deferred, or restarted only in a daytime window? A forced restart kills the
  night's batch and then waits at the FileVault screen.
- Does the profile log out idle users? That stops the factory. Screen lock is fine.

Install (each needs your password once):

- Xcode command line tools: `xcode-select --install` (git; macOS already ships `jq`, `openssl`, `curl`).
- Docker Desktop for Apple Silicon.
- Tailscale (the standalone app or the App Store one). MDM may need to approve its network extension.
- GitHub CLI: the `.pkg` from https://github.com/cli/cli/releases.
- Caffeine.

Docker Desktop: open it, accept, Settings, General, "Start Docker Desktop when you sign in" on. Tailscale: sign in,
and set it to start at login. Then:

```bash
docker run --rm hello-world
```

## 2. Reaching it from the laptop

The mini's Tailscale name is `kims-software-factory` (100.102.1.77). A wipe registers a new machine; remove the
stale one in the Tailscale admin console so the name stays unambiguous.

Screen Sharing (System Settings, General, Sharing) is the main way in, and copy and paste works across it:

```bash
open vnc://kims-software-factory
```

Connect by that address, not a saved entry in the Screen Sharing menu, which can still point at the old machine.
If the connection fails, check `tailscale status` on the laptop first: an offline mini is asleep, rebooted and
waiting at the FileVault screen, or logged out.

Never log out of the account. A logout stops Docker, and the one time it was tried the mini appeared to shut
down. Lock instead (Control-Command-Q).

Optional, for pasting one-liners: Remote Login on in the same Sharing pane, allowed for this account only. MDM may
block this. Let your laptop's GitHub keys in:

```bash
mkdir -p ~/.ssh && curl -s https://github.com/kmaida.keys >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

Then from the laptop: `ssh kimmaida-mini@kims-software-factory`.

## 3. Secrets and environment

If you saved the old `factory-secrets` before the wipe, put them back. If not, generate a new client secret for the
`urn:factory:mini` Application in the Keycard zone (the client ID stays the same).

```bash
mkdir -p ~/factory-secrets && chmod 700 ~/factory-secrets
printf '%s' 'CLIENT_ID' > ~/factory-secrets/keycard_client_id
printf '%s' 'CLIENT_SECRET' > ~/factory-secrets/keycard_client_secret
chmod 400 ~/factory-secrets/*
```

Pick a new ntfy topic (a long random name) unless you kept the old one, and subscribe to it on your phone.
Exports go in `~/.zshenv`, not `~/.zshrc`, so ssh one-liners see them:

```bash
echo 'export FACTORY_SECRETS_DIR=~/factory-secrets' >> ~/.zshenv
echo "export FACTORY_NOTIFY_URL='https://ntfy.sh/TOPIC'" >> ~/.zshenv
```

## 4. Repos

The workshop repo is internal to `keycard-sandbox`, so the mini needs your GitHub login to clone it:

```bash
gh auth login -w
gh auth setup-git
git clone https://github.com/kmaida/software-factory.git ~/software-factory
git clone https://github.com/keycard-sandbox/keycard-workshop-platform.git ~/kwp
```

## 5. Image and pin

```bash
cd ~/software-factory && docker build -t factory-sandbox .
```

The new image will not match `IMAGE_ID` in `factory`; builds are not byte-identical. Send its ID to your phone
instead of copying 64 characters by hand:

```bash
docker image inspect --format '{{.Id}}' factory-sandbox | curl -s -d @- "$FACTORY_NOTIFY_URL"
```

Give that ID to Claude on the laptop for the one-line pin PR, merge it, then `git pull` on the mini.

## 6. Canary, then the queue

```bash
./canary.sh kmaida/test-repo
```

Wait for exit 0. Then rebuild the queue from `~/kwp/factory-tasks` (only tasks whose PRs have not merged) and run
the night as the README's "Before a real night" says. If `runs/` and `queue/done|failed|held` were not saved before
the wipe, the archives start empty; `depends_on` still resolves against what is merged on the base.

## 7. Prove the reboot path once

Restart the mini. At the FileVault screen type the "Software Factory" password. You should land on its desktop
with Docker, Tailscale and Caffeine coming up on their own. Lock the screen (Control-Command-Q) and check from the
laptop over Tailscale.

For a restart you plan, `sudo fdesetup authrestart` skips the FileVault screen once, so the mini comes back on the
network without you at the keyboard. Test whether it also lands logged in; if it stops at the login window, Docker
will not be running until someone logs in.

## After every unplanned reboot

The factory is down until someone types the account's password at the mini's keyboard. A running batch leaves its
task in the queue (nothing pushed) or retries it, so rerun `batch` with `--continue` after logging in.
