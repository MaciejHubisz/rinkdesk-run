# RinkDesk (run-only)

No source code and no data dumps. `./start.sh --start` pulls the `:latest`
Docker images and starts the desk. This is the only `start.sh`.

If a sibling `../rinkdesk` source tree is on disk (or `RINKDESK_SRC` is set),
`--start` builds and publishes fresh images from it first, then pulls and
runs. Without it, the script just pulls and runs.

Linux only — this repo is meant to run on a remote Linux host, usually over
SSH.

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
sudo scripts/sudo/setup-host.sh maciej
```

The `scripts/sudo/` folder marks the one script that must be run as root
(everything else, including `./start.sh`, runs as the operator without sudo).
That installs Homebrew for `maciej` (plus the system tools it needs), sets up
rootless prerequisites (`uidmap`, a subuid range, Ubuntu's AppArmor user-namespace
rule), and enables lingering. Then, with no sudo at all, `./start.sh` installs
Podman + Compose from Homebrew and runs the desk rootless. On Fedora atomic
desktops (Bazzite/Silverblue), `podman` is already there.

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
needs lingering, which `scripts/sudo/setup-host.sh` enables). Manage it with:

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

## Deploy on a new machine

End-to-end on a fresh Linux host. Steps 1 and 4 need an administrator
(`sudo`); everything in between runs as the operator.

1. **One-time host setup, as root.** Installs build tools, Homebrew, rootless
   prerequisites, and lingering for the operator account. This is the only
   script that needs sudo — the `scripts/sudo/` folder name says so:

   ```bash
   sudo scripts/sudo/setup-host.sh maciej
   ```

2. **As the operator, clone and start.** No sudo: Homebrew installs Podman.

   ```bash
   git clone git@github.com:MaciejHubisz/rinkdesk-run.git
   cd rinkdesk-run
   ./start.sh --start
   ./start.sh --install-service     # start on boot, survive SSH logout
   ```

3. **Put nginx in front (optional).** The app listens on `127.0.0.1:8765`
   (`--port` / `RINKDESK_PORT`). nginx terminates TLS and exposes only the
   read-only live page; the desk stays local.

4. **Install nginx + Certbot and enable the site, as root:**

   ```bash
   sudo apt-get install -y nginx certbot python3-certbot-nginx
   ```

   `/etc/nginx/sites-available/rinklive.conf`:

   ```nginx
   server {
       server_name rinklive.nfy.pl;

       location = / {
           return 301 /live/;
       }

       location /live {
           proxy_pass http://127.0.0.1:8765;
           proxy_http_version 1.1;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
       }

       location / {
           return 404;
       }

       listen 443 ssl; # managed by Certbot
       ssl_certificate /etc/letsencrypt/live/rinklive.nfy.pl/fullchain.pem; # managed by Certbot
       ssl_certificate_key /etc/letsencrypt/live/rinklive.nfy.pl/privkey.pem; # managed by Certbot
       include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
       ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
   }

   server {
       if ($host = rinklive.nfy.pl) {
           return 301 https://$host$request_uri;
       } # managed by Certbot

       listen 80;
       server_name rinklive.nfy.pl;
       return 404; # managed by Certbot
   }
   ```

   Enable it and obtain the certificate (Certbot rewrites the `ssl_*` lines
   and the port 80 redirect on first run):

   ```bash
   sudo ln -s /etc/nginx/sites-available/rinklive.conf /etc/nginx/sites-enabled/
   sudo nginx -t && sudo systemctl reload nginx
   sudo certbot --nginx -d rinklive.nfy.pl
   ```

What the config does:

- `location /` returns 404, so nothing except the live page is reachable
  through the public hostname.
- `location = /` redirects to `/live/`; `location /live` reverse-proxies to
  the container port with the usual forwarded headers.
- TLS is on 443; port 80 only redirects to HTTPS (managed by Certbot).

Change `rinklive.nfy.pl` and `8765` to match your hostname and `--port`.

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
start.sh                      entry point
scripts/
  lib/                        shared bash helpers (common, platform, config, engine)
  sudo/setup-host.sh          one-time admin setup, run as root (Homebrew + linger)
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

If pull fails, the `rinkdesk-backend` and `rinkdesk-web` images may still be
private in the registry — the publisher must set them Public.
