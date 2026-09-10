# RinkDesk (run-only)

No source code and no data dumps. `./start.sh --start` pulls Docker images
and starts the desk. This is the only `start.sh`.

Proprietary — © Maciej Hubisz. All rights reserved. Use, modify, fork, or
redistribute only with the author's written permission. See `LICENSE`.

## Quick start

Browser after starting: <http://127.0.0.1:8765/> — sign in `admin` / `admin`
(or `ref` / `ref`).

### macOS (from scratch, Homebrew only)

1. Install [Homebrew](https://brew.sh) if you do not have it.
2. In Finder, double-click **`scripts/macos/start.command`**.

   The first time it asks before installing a Docker runtime with Homebrew
   (`colima` + `docker`); say yes and it does the rest. Later runs just start
   the desk. Double-click `scripts/macos/stop.command` to stop (data kept),
   and `scripts/macos/start-funnel.command` to share the live page.

   Prefer the Terminal? The same thing, one line:

   ```bash
   ./start.sh --start
   ```

macOS notes:

- The first run downloads images and can take a few minutes.
- `colima` is the no-cost, no-login Docker runtime we install. If you already
  run Docker Desktop, the script uses that instead.
- Double-clicking a `.command` opens a Terminal window that stays open so you
  can read any message.

### Linux

```bash
./start.sh --start
```

Docker or Podman must be installed and running. On Fedora atomic desktops
(Bazzite/Silverblue), `podman` is already there.

Tab completion for the flags works like any other Linux command. Enable it
once by sourcing the completion script (add the line to your `~/.bashrc` to
make it permanent):

```bash
source scripts/linux/start-completion.bash
# then ./start.sh --for<TAB> → --force-recreate / --force-pull
```

### Windows (WSL + Docker)

1. PowerShell **as Administrator**: `wsl --install` (Ubuntu is fine). Reboot if asked.
2. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
   and turn on **Settings → Resources → WSL integration** for that distro.
3. Clone and start:

```powershell
git clone https://github.com/MaciejHubisz/rinkdesk-run.git
cd rinkdesk-run
.\scripts\windows\windows.cmd --start
```

## Commands

| Command | What it does |
|---|---|
| `./start.sh --start` | Pull images, start or resume, keep data |
| `./start.sh --start --export-path DIR` | Same, and bind snapshot exports to a local folder |
| `./start.sh --start --protocols-path DIR` | Same, and write generated protocol PDFs to a local folder |
| `./start.sh --start --force-pull` | Skip local build; pull from hub (fail if pull fails) |
| `./start.sh --force-recreate` | Wipe Postgres, pull, start empty |
| `./start.sh --stop` | Stop containers (data kept) |
| `./start.sh --manual` | How the desk works |

Windows equivalents: replace `./start.sh` with `.\scripts\windows\windows.cmd`.
macOS double-click equivalents live in `scripts/macos/`.

## Read-only live page

A standalone scoring page (table + games, auto-refresh, light/dark, PL/EN/CS) is
served at `http://127.0.0.1:8765/live/` and is not linked to the desk.

Share just that page on the internet with Tailscale Funnel — the desk stays
private. The script provisions everything from scratch: installs Tailscale,
starts the daemon, logs in (interactive the first time), starts the desk if
needed, and enables the Funnel:

```bash
./start-funnel.sh                 # https://<machine>.<tailnet>.ts.net/live/
./start-funnel.sh --path /scores  # different URL path
./start-funnel.sh --authkey KEY   # non-interactive login
./start-funnel.sh --status
./start-funnel.sh --stop
```

On Windows use `.\scripts\windows\start-funnel.cmd`; on macOS double-click
`scripts/macos/start-funnel.command`. All accept the same flags.

Auto-refresh and the live port live in `.env`
(`RINKDESK_LIVE_REFRESH_SECONDS`, `RINKDESK_LIVE_PORT`). See
`rinkdesk/docs/live-page.md` in the source repo.

## Folders and files

```
start.sh, start-funnel.sh     entry points (bash; work on Linux + macOS + WSL)
scripts/
  lib/                        shared bash helpers (common, platform, config, engine, tailscale)
  linux/start-completion.bash tab completion for bash
  macos/*.command             Finder double-click launchers
  windows/                    Windows launchers (.cmd/.ps1) and helpers
  manual.txt                  text shown by --manual
docker-compose.yml            pre-built images only
.env                          image tag + live-page settings
protocols/                    generated protocol PDFs (default location)
team-logos/                   logo PNGs the app reads (user-provided)
```

## Data and folders

Without `--export-path`, snapshot JSON lives in the Docker volume
`rinkdesk-exports`. With it, Settings → export writes into that folder
(`archive/` plus the latest file) and copies each team’s logo PNG next to the
JSON; import restores both. Pass the flag each time you start, or set
`RINKDESK_EXPORTS_PATH`.

Protocol PDFs are written to the `protocols/` folder next to `start.sh` — always
the same file per match, overwritten on every save. Pass `--protocols-path DIR`
(or set `RINKDESK_PROTOCOLS_PATH`) to put them in another folder instead — e.g.
`G:\My Drive\protocols` to share them via Google Drive (see the Windows setup
below).

```bash
./start.sh --start --export-path ~/rinkdesk-exports
./start.sh --start --protocols-path ~/rinkdesk-protocols
```

```powershell
.\scripts\windows\windows.cmd --start --export-path D:\rinkdesk-exports
.\scripts\windows\windows.cmd --start --protocols-path D:\rinkdesk-protocols
```

Team logos: drop a PNG into the `team-logos/` folder next to `start.sh`, named
after the team short name (e.g. `orly_logo.png` for `ORŁY`). There is no upload
and no per-team field — a missing file simply shows a neutral "no logo" crest.
Export bundles those images with the JSON dump; import restores them. See
`team-logos/README.md`.

If pull fails, GHCR packages `rinkdesk-backend` and `rinkdesk-web` may still
be private — the publisher must set them Public.

## Windows: share protocols through Google Drive

So new protocol PDFs are shared the moment they are written, run the one-time
helper once per PC (PowerShell **as Administrator** from `rinkdesk-run`):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\Setup-ProtocolsDrive.ps1 `
  -OwnerEmail maciej@example.com -Share ref@example.com,trener@example.com
```

It installs official Google Drive for desktop, restricts sign-in to `-OwnerEmail`,
mounts My Drive as drive letter `-DriveLetter` (default `G`), and creates the
protocols folder + `_setup.txt` marker in My Drive. Expect exactly one interactive
Google login; everything else is automatic. If the drive was not ready yet, re-run
the same command (idempotent). One step stays manual: sharing the folder — Drive for
desktop cannot grant sharing from the CLI, so share the protocols folder once in the
browser window it opens (the share list is printed). Then point the app at it:

```powershell
.\scripts\windows\windows.cmd --start --protocols-path "G:\My Drive\protocols"
```

See the top of `scripts\windows\Setup-ProtocolsDrive.ps1` for all options.
