# RinkDesk (run-only)

This folder starts the rink-clerk desk. It has **no source code and no data dumps**.
`./start.sh --start` pulls Docker images and runs the same stack as the full project.

## Windows (WSL + Docker)

1. PowerShell **as Administrator**: `wsl --install` (Ubuntu is fine). Reboot if asked.
2. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
   and turn on **Settings → Resources → WSL integration** for that distro.
3. Clone this repository (Git for Windows or inside WSL).
4. In this folder:

```powershell
.\start.ps1 --start
```

Or double-click `start.cmd`. A browser should open http://127.0.0.1:8765/

Sign in: `admin` / `admin` (or `ref` / `ref`).

## Linux / macOS / already inside WSL

```bash
./start.sh --start
```

Same flags as the source tree: `--stop`, `--force-recreate` (empty database),
`--manual`, `-p 8765`.

## Commands

| Command | What it does |
|---|---|
| `./start.sh --start` | Pull images, start or resume, keep data |
| `./start.sh --force-recreate` | Wipe Postgres, pull, start empty |
| `./start.sh --stop` | Stop containers (data kept) |
| `./start.sh --manual` | How the desk works |

First start needs the internet (image pull). Later starts reuse local images.

## What is not here on purpose

- No `backend/`, `web/`, or `database/`
- Exports and the factory snapshot live **inside the images / Docker volumes**,
  not as files you can browse in this clone

If pull fails, the images may still be private on the registry. The person who
publishes them must set GitHub Packages `rinkdesk-backend` and `rinkdesk-web`
to **Public**, or you log in with a token that can read those packages.
