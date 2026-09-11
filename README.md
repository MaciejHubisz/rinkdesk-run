# RinkDesk (run-only)

No source code and no data dumps. `./start.sh --start` pulls Docker images
and starts the desk. This is the only `start.sh`.

Linux only — this repo is meant to run on a remote Linux host, usually over
SSH. There are no Windows or macOS launchers.

Proprietary — © Maciej Hubisz. All rights reserved. Use, modify, fork, or
redistribute only with the author's written permission. See `LICENSE`.

## Quick start

```bash
./start.sh --start
```

Browser after starting: <http://127.0.0.1:8765/> — sign in `admin` / `admin`
(or `ref` / `ref`).

On a fresh Linux host the script installs a container runtime for you. If
your account can `sudo`, it installs Docker with the package manager. If it
cannot, ask an administrator to run the one-time host setup once:

```bash
sudo scripts/linux/setup-host.sh maciej
```

That installs Homebrew for `maciej` (plus the few system tools it needs) and
enables lingering. Then, with no sudo at all, `./start.sh` installs Podman +
Compose from Homebrew and runs the desk rootless. On Fedora atomic desktops
(Bazzite/Silverblue), `podman` is already there.

Tab completion for the flags works like any other Linux command. Enable it
once by sourcing the completion script (add the line to your `~/.bashrc` to
make it permanent):

```bash
source scripts/linux/start-completion.bash
# then ./start.sh --for<TAB> → --force-recreate / --force-pull
```

## Commands

| Command | What it does |
|---|---|
| `./start.sh --start` | Pull images, start or resume, keep data |
| `./start.sh --start --export-path DIR` | Same, and bind snapshot exports to a local folder |
| `./start.sh --start --protocols-path DIR` | Same, and write generated protocol PDFs to a local folder |
| `./start.sh --start --force-pull` | Skip local build; pull from hub (fail if pull fails) |
| `./start.sh --force-recreate` | Wipe Postgres, pull, start empty |
| `./start.sh --update` | Pull newer images and recreate, keeping data |
| `./start.sh --status` | Show container status |
| `./start.sh --logs [SERVICE]` | Follow logs (backend/web/db, all by default) |
| `./start.sh --stop` | Stop containers (data kept) |
| `./start.sh --install-service` | Run on boot via systemd (and start now) |
| `./start.sh --uninstall-service` | Remove the systemd unit |
| `./start.sh --manual` | How the desk works |

Global `-y` / `--yes` answers every prompt (unattended installs and updates
over SSH). You can also set `RINKDESK_ASSUME_YES=1`.

## Running over SSH

The desk is a long-running service, so run it on the host rather than in an
SSH session that will end. Install the systemd unit once:

```bash
./start.sh --install-service
```

This starts RinkDesk now and on every boot, and keeps it running after you
log out. Root gets a system unit; a regular user gets a user unit (no sudo;
needs lingering, which `setup-host.sh` enables). Manage it with:

```bash
# regular user (no sudo):
systemctl --user status rinkdesk
journalctl --user -u rinkdesk -f

# root:
systemctl status rinkdesk
journalctl -u rinkdesk -f

./start.sh --update          # pull new images, keep data
./start.sh --status
```

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

Auto-refresh and the live port live in `.env`
(`RINKDESK_LIVE_REFRESH_SECONDS`, `RINKDESK_LIVE_PORT`). See
`rinkdesk/docs/live-page.md` in the source repo.

## Folders and files

```
start.sh, start-funnel.sh     entry points
scripts/
  lib/                        shared bash helpers (common, platform, config, engine, tailscale)
  linux/setup-host.sh         one-time admin setup (Homebrew + linger)
  linux/start-completion.bash tab completion for bash
  manual.txt                  text shown by --manual
docker-compose.yml            pre-built images only
.env                          image tag + live-page settings
protocols/                    generated protocol PDFs (default location)
team-logos/                   logo PNGs the app reads (user-provided)
```

## Data and folders

Without `--export-path`, snapshot JSON lives in the Docker volume
`rinkdesk-exports`. With it, Settings → export writes into that folder
(`archive/` plus the latest file) and copies each team's logo PNG next to the
JSON; import restores both. Pass the flag each time you start, or set
`RINKDESK_EXPORTS_PATH`.

Protocol PDFs are written to the `protocols/` folder next to `start.sh` — always
the same file per match, overwritten on every save. Pass `--protocols-path DIR`
(or set `RINKDESK_PROTOCOLS_PATH`) to put them in another folder instead.

```bash
./start.sh --start --export-path ~/rinkdesk-exports
./start.sh --start --protocols-path ~/rinkdesk-protocols
```

Team logos: drop a PNG into the `team-logos/` folder next to `start.sh`, named
after the team short name (e.g. `orly_logo.png` for `ORŁY`). There is no upload
and no per-team field — a missing file simply shows a neutral "no logo" crest.
Export bundles those images with the JSON dump; import restores them. See
`team-logos/README.md`.

If pull fails, GHCR packages `rinkdesk-backend` and `rinkdesk-web` may still
be private — the publisher must set them Public.
