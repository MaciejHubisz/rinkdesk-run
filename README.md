# RinkDesk (run-only)

No source code and no data dumps. `./start.sh --start` pulls Docker images
and starts the desk.

## Windows (WSL + Docker)

1. PowerShell **as Administrator**: `wsl --install` (Ubuntu is fine). Reboot if asked.
2. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
   and turn on **Settings → Resources → WSL integration** for that distro.
3. Clone and start:

```powershell
git clone https://github.com/MaciejHubisz/rinkdesk-run.git
cd rinkdesk-run
.\install\windows.cmd --start
```

Browser: http://127.0.0.1:8765/ — sign in `admin` / `admin` (or `ref` / `ref`).

## Linux / macOS / already inside WSL

```bash
./start.sh --start
```

| Command | What it does |
|---|---|
| `./start.sh --start` | Pull images, start or resume, keep data |
| `./start.sh --force-recreate` | Wipe Postgres, pull, start empty |
| `./start.sh --stop` | Stop containers (data kept) |
| `./start.sh --manual` | How the desk works |

If pull fails, GHCR packages `rinkdesk-backend` and `rinkdesk-web` may still
be private — the publisher must set them Public.
