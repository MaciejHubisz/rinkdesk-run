# RinkDesk (run-only)

No source code and no data dumps. `./start.sh --start` pulls the `:latest`
Docker images and starts the desk. This is the only `start.sh`.

`common/` is vendored from the shared framework repo (the source commit is in
`common/VENDORED_FROM`), so this repo is self-contained: clone it and run.

If a sibling `../rinkdesk` source tree is on disk (or `RINKDESK_SRC` is set),
`--start`, `--update` and `--force-recreate` build fresh images from it first
and run those local images. Without it, the script just pulls and runs.

The images are private. The host setup logs the operator in when you run it
with `--install-service`: if no token is configured it asks for one (with a
link to create it), logs in, and saves it to `registry.env` (gitignored, mode
600) so later `--start`/`--update` log in automatically.

```bash
sudo scripts/setup-server-as-root.sh maciej --install-service
```

Use a token with the `read:packages` scope — **not** your GitHub account
password. On podman the registry login is written to
`~/.config/containers/auth.json` so it survives reboots.

Linux is the target (a remote host, usually over SSH). It also runs on macOS:
`start.sh` sources `scripts/macos.sh` on Darwin to start Homebrew's PATH and a
container runtime (Colima / Docker Desktop / OrbStack / Podman machine) first.
`--install-service` installs a launchd agent there instead of a systemd unit.

Proprietary — © Maciej Hubisz. All rights reserved. Use, modify, fork, or
redistribute only with the author's written permission. See `LICENSE`.

## The two things you can run

RinkDesk has two entry points. Which one you use depends on who you are:

| Who | Command | Needs sudo? | What it does |
|---|---|---|---|
| Operator, day to day | `./start.sh --start` | no | Pulls the images and runs the desk |
| Administrator, once per server | `sudo scripts/setup-server-as-root.sh maciej` | yes | Prepares a fresh server so the operator can run `./start.sh` |

The admin script's name says exactly what it is: it **sets up the server**,
and you run it **as root**. Everything else in this repo runs as the operator,
without sudo.

## Quick start

```bash
./start.sh --start
```

Browser after starting: <http://127.0.0.1:8765/> — sign in `admin` / `admin`
(or `ref` / `ref`).

On a fresh Linux server the script installs a container runtime for you. If
your account can `sudo`, it installs Docker with the package manager. If it
cannot, ask an administrator to prepare the server once:

```bash
sudo scripts/setup-server-as-root.sh maciej
```

That installs Homebrew for `maciej` (plus the system tools it needs), sets up
rootless prerequisites (`uidmap`, a subuid range, Ubuntu's AppArmor user-namespace
rule), enables lingering, and adds a `rinkdesk` alias to `~/.bashrc`. Then, with
no sudo at all, `./start.sh` installs Podman + Compose from Homebrew and runs the
desk rootless. On Fedora atomic desktops (Bazzite/Silverblue), `podman` is
already there.

The `rinkdesk` alias points at this checkout's `start.sh`, so in a new shell you
can run the desk from anywhere with the same flags:

```bash
rinkdesk --start      # or --update, --status, --logs, …
```

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
| `./start.sh --start` | Pull images, apply newer ones, start or resume, keep data |
| `./start.sh --start --export-path DIR` | Same, and bind snapshot exports to a local folder |
| `./start.sh --start --protocols-path DIR` | Same, and write generated protocol PDFs to a local folder |
| `./start.sh --start --force-pull` | Skip local build; pull from ghcr (fail if pull fails) |
| `./start.sh --force-recreate` | Wipe Postgres, JSON exports, and protocol PDFs; build or pull; start empty (only built-in logins, default snapshot import stays available on demand) |
| `./start.sh --update` | Fast-forward the run repo, build from the local source (if present) or pull newer images, recreate the app containers, keep data |
| `./start.sh --no-self-update` | Do not git-pull this checkout before start/update |
| `./start.sh --status` | Show container status |
| `./start.sh --login` | Log in to the image registry (needed for the private package) |
| `./start.sh --logs [SERVICE]` | Follow logs (backend/web/db, all by default) |
| `./start.sh --stop` | Stop containers (data kept) |
| `./start.sh --install-service` | Run on boot via systemd (launchd on macOS), and start now |
| `./start.sh --uninstall-service` | Remove the systemd unit / launchd agent |
| `./start.sh --manual` | How the desk works |

Global `-y` / `--yes` answers every prompt (unattended installs and updates
over SSH). You can also set `RINKDESK_ASSUME_YES=1`.

## Updating the run repo itself

`--start` and `--update` first fast-forward this checkout from `origin` (when it
is a clean git clone with a tracking branch and there is no sibling `../rinkdesk`
source tree), then re-exec the updated script. So after changing `start.sh` or
`docker-compose.yml` on a run-only host you no longer `git pull` by hand — just
run the same command. It fails soft when offline or when there are local
changes, and never touches a dirty tree.

Skip it for one run with `--no-self-update`, or disable it entirely with
`RINKDESK_NO_SELF_UPDATE=1`.

## Deploying from GitHub

The `rinkdesk` repo's **Deploy** workflow can SSH here and run
`./start.sh --update` after a successful image publish, so a push to `main`
reaches the desk without a manual step. It is off until configured; the host
side is one command:

```bash
sudo scripts/setup-server-as-root.sh maciej --deploy-key
```

It generates the key pair, authorizes the public half, and prints the private
half once for the GitHub secret. Already have a key?
`--deploy-key-file /path/to/key.pub`.

Full setup (GitHub secrets and variables): `rinkdesk/docs/deploy.md`.

## Running over SSH

The desk is a long-running service, so run it on the host rather than in an
SSH session that will end. Install the systemd unit once:

```bash
./start.sh --install-service
```

This starts RinkDesk now and on every boot, and keeps it running after you
log out. Root gets a system unit; a regular user gets a user unit (no sudo).

**A user unit only starts at boot if lingering is enabled.** Without it, your
systemd user manager is started on login, so after a reboot the desk stays
down until someone SSHes in. The host script enables lingering for the operator
(`sudo scripts/setup-server-as-root.sh maciej`); re-run it if you are unsure.
Check it with `loginctl show-user maciej | grep Linger` (→ `Linger=yes`).

Manage the service with:

```bash
# regular user (no sudo):
systemctl --user status rinkdesk
journalctl --user -u rinkdesk -f

# root:
systemctl status rinkdesk
journalctl -u rinkdesk -f

./start.sh --update          # rebuild/pull images, keep data
./start.sh --status
```

To confirm it really comes back, `sudo reboot` and check
`systemctl --user status rinkdesk` after you reconnect.

## Deploy on a new machine

End-to-end on a fresh Linux host. Deployment has two phases, split by
privilege: **Phase 1 (root)** prepares the host, **Phase 2 (operator, no
sudo)** installs Podman and starts the desk on boot. Step 3 (nginx + TLS) is
also root and optional.

`scripts/setup-server-as-root.sh` is the only script that needs root, and it can
run both phases for you:

```bash
# host setup + install the desk to start on every boot, in one command
sudo scripts/setup-server-as-root.sh maciej --install-service
```

Without `--install-service` it does Phase 1 only and prints the Phase 2
command. The manual steps are below.

1. **Phase 1 — one-time host setup, as root.** Installs build tools, Homebrew,
   rootless prerequisites, and lingering for the operator account:

   ```bash
   sudo scripts/setup-server-as-root.sh maciej
   ```

2. **Phase 2 — as the operator, clone and start.** No sudo: Homebrew installs
   Podman. `--install-service` also enables the unit so the desk starts on
   every boot (lingering from Phase 1 makes the user unit survive logout and
   reboot):

   ```bash
   git clone git@github.com:MaciejHubisz/rinkdesk-run.git
   cd rinkdesk-run
   ./start.sh --start
   ./start.sh --install-service     # start on boot, survive SSH logout
   ```

   Verify it will come back after a reboot:

   ```bash
   loginctl show-user maciej | grep Linger   # → Linger=yes
   systemctl --user status rinkdesk
   ```

3. **Phase 1b — public HTTPS site (optional), as root.** The desk listens on
   `127.0.0.1:8765`; nginx terminates TLS and exposes only the read-only live
   page. This is a small config of its own under `scripts/admin/`: edit
   `admin.env` (hostname, port, Let's Encrypt email), and the setup script
   applies it from `nginx-site.conf.template`:

   ```bash
   # scripts/admin/admin.env:
   #   RINKDESK_DOMAIN="rinklive.nfy.pl"
   #   RINKDESK_PORT="8765"
   #   RINKDESK_TLS_EMAIL="you@example.com"

   sudo scripts/setup-server-as-root.sh maciej --install-nginx
   ```

   That installs nginx + certbot (apt/dnf/pacman/zypper), writes the site
   config, opens firewalld, allows nginx to proxy under SELinux, and obtains
   the certificate. The values can also be passed as flags (`--domain`,
   `--port`, `--email`, `--no-tls`). Combine everything in one command:

   ```bash
   sudo scripts/setup-server-as-root.sh maciej --install-service --install-nginx
   ```

   What the site does (see `scripts/admin/nginx-site.conf.template`):

   - `location /` returns 404, so nothing except the live page is reachable
     through the public hostname.
   - `location = /` redirects to `/live/`; `location /live` reverse-proxies to
     the container port with the usual forwarded headers.
   - Certbot adds TLS on 443 and makes port 80 redirect to HTTPS.

> The compose file publishes `${RINKDESK_PORT:-8765}:80` on all interfaces, so
> the desk is also reachable directly on `:8765` unless a firewall blocks it.
> If that is not wanted, bind it to localhost (`127.0.0.1:8765:80`) so only
> nginx can reach it.

## Read-only live page

A standalone scoring page (table + games, auto-refresh, light/dark, PL/EN/CS) is
served at `http://127.0.0.1:8765/live/` and is not linked to the desk.

Auto-refresh lives in `.env` (`RINKDESK_LIVE_REFRESH_SECONDS`). See
`rinkdesk/docs/live-page.md` in the source repo.

## Folders and files

```
app.conf                        app identity read by the shared scripts
start.sh                        run the desk; wraps common/ops/start.sh
common/                         submodule: reusable backend, web and ops framework
scripts/
  setup-server-as-root.sh       wraps common/ops/setup-server-as-root.sh
  macos.sh                      macOS runtime bootstrap, sourced by start.sh
  admin/                        public-site config (mini-project):
    admin.env                     domain, port, Let's Encrypt email
    nginx-site.conf.template      nginx site, applied by setup-server-as-root.sh
  linux/start-completion.bash   tab completion for bash
  manual.txt                    text shown by --manual
docker-compose.yml              pre-built images only
.env                            optional RINKDESK_* overrides (empty by default)
exports/                        generated snapshot JSON (default location)
protocols/                      generated protocol PDFs (default location)
graphics/logos/                  logo overrides the app reads (user-provided)
```

## Data and folders

Snapshot JSON lives in the `exports/` folder next to `start.sh`. Settings →
export writes `archive/` plus the latest file there, and copies each team's logo
PNG next to the JSON; import restores both. Pass `--export-path DIR` (or set
`RINKDESK_EXPORTS_PATH`) to put exports in another folder instead.

Protocol PDFs are written to the `protocols/` folder next to `start.sh` — always
the same file per match, overwritten on every save. Pass `--protocols-path DIR`
(or set `RINKDESK_PROTOCOLS_PATH`) to put them in another folder instead.

```bash
./start.sh --start --export-path ~/rinkdesk-exports
./start.sh --start --protocols-path ~/rinkdesk-protocols
```

Team logos: the app ships with a set of default logos baked into the image. To
change one, drop a PNG into the `graphics/logos/` folder next to `start.sh`, named
after the team short name (e.g. `orly_logo.png` for `ORŁY`). A file here overrides
the bundled default for that team; teams without a file here keep the default.
There is no upload and no per-team field — a missing file simply shows a neutral
"no logo" crest. Export bundles those images with the JSON dump; import restores
them. See `graphics/logos/README.md`.

If pull fails, the `rinkdesk-backend` and `rinkdesk-web` images are private on
ghcr.io — log in once with a `read:packages` token (see the top of this file).
