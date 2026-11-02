# hetzner-docker

A Docker Compose stack for a small VPS: a Rust API, a SvelteKit site in 2 versions (2 branches of the same repository), a Takuzu game with a daily puzzle, a static page that a job rebuilds, a resource dashboard (Beszel), and an agent that sends the metrics of the VPS to another server (vmagent). The images are built and tested on a local machine, then sent to the VPS over SSH: the VPS needs no compiler and no source code. Caddy runs on the host, in front of the containers.

## Layout

| Path | Content |
|------|---------|
| `compose.yaml` | The production stack, on the VPS. |
| `compose.local.yaml` | The changes for a local test: test env files, a Caddy container on `localhost:8080`, a local web root. |
| `images/<name>/Dockerfile` | One image per project. The build context is the root of the project repository, so the file can also live in that repository. `Dockerfile.dockerignore` next to it lists the files that stay out of the image. |
| `env/*.env.example` | The keys of each env file, with the values of the local test. The real `env/*.env` files exist only on the VPS. |
| `local/Caddyfile` | The Caddy of the local test. |
| `caddy/*.caddy` | The Caddy sites of this stack. `just caddy` installs them in `/etc/caddy/managed/` on the VPS, and touches nothing else. |
| `caddy/Caddyfile` | A minimal main Caddyfile, for a host that runs only this stack. `just caddy` does not install it. |
| `scripts/beszel-setup.sh` | Connects the Beszel agent to its hub (`just beszel-setup`, `just local-beszel`). |
| `vmagent/scrape.yaml` | The targets of vmagent: the services that give metrics, and how to reach them. |
| `justfile` | All the commands. Run `just` to list them. |
| `src/` (not in git) | The sources of the images, cloned by `just init`. |
| `data/` (not in git) | The files mounted into the containers: static files, fonts, web roots. |

## Services

| Service | Image | Port on the host | Source | Env files | Mounted |
|---------|-------|------------------|--------|-----------|---------|
| `vps-back` | `tomplanche/vps-back:main` | `127.0.0.1:8000` | [vps-back](https://github.com/TomPlanche/vps-back), `main` | `env/vps-back.env` | `data/vps-back/static` on `/data/static` |
| `site` | `tomplanche/portfolio:main` | `127.0.0.1:3000` | [portfolio-v222](https://github.com/TomPlanche/portfolio-v222), `main` | `env/site.env` | `data/fonts` |
| `next-site` | `tomplanche/portfolio:next` | `127.0.0.1:3001` | [portfolio-v222](https://github.com/TomPlanche/portfolio-v222), `next` | `env/site.env`, then `env/next-site.env` | `data/fonts` |
| `atkuzu` | `tomplanche/atkuzu:main` | `127.0.0.1:3002` | [atkuzu](https://tangled.org/tomplanche.com/atkuzu), `main` | `env/atkuzu.env` | `data/atkuzu` on `/data` |
| `atkuzu-daily` | `tomplanche/atkuzu-daily:main` | none (a job) | [atkuzu](https://tangled.org/tomplanche.com/atkuzu), `main` | `env/atkuzu-daily.env` | `data/atkuzu/daily` on `/app/static/daily` |
| `sifa-page` | `tomplanche/sifa-page:main` | none (a job) | [sifa-page](https://github.com/singi-labs/sifa-page), `main` | none | `/var/www/sifa-page` on `/out` |
| `beszel` | `henrygd/beszel:0.21.1` | `127.0.0.1:8090` | [Beszel](https://github.com/henrygd/beszel) hub | `env/beszel.env` | `data/beszel/hub`, `data/beszel/socket` |
| `beszel-agent` | `henrygd/beszel-agent:0.21.1` | none (host network) | [Beszel](https://github.com/henrygd/beszel) agent | `env/beszel-agent.env` (written by `just beszel-setup`) | `data/beszel/agent`, `data/beszel/socket`, the Docker socket (read only) |
| `vmagent` | `victoriametrics/vmagent:v1.154.0` | host network: `127.0.0.1:8429` | [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics) agent | `env/vmagent.env` | `vmagent/` on `/etc/vmagent`, `data/vmagent` |

- The ports listen on `127.0.0.1` only: the Caddy of the host is the only way in.
- `vps-back` serves the files of `data/vps-back/static` under `/static/`. With `GITHUB_TOKEN`, it also writes `github-stats.json` there.
- `next-site` reads `env/site.env` first, then `env/next-site.env`. A value in the second file wins. So `env/next-site.env` holds only the values that differ, for example `MAINTENANCE=true`.
- The front image gets its last commit at build time: `just build` reads it from git. The front makes no GitHub API call for it.
- The fonts of the site have a license that does not allow them in a public image. They are mounted from `data/fonts`. Without them, the site uses fallback fonts.
- `atkuzu` keeps its SQLite database (the atproto OAuth sessions and state) in `data/atkuzu/atkuzu.db`, and it applies its migrations at start-up. It finds its public URL in the `X-Forwarded-*` headers of Caddy. The OAuth login works only on a public HTTPS domain (`OAUTH_DOMAIN`).
- The dailies of atkuzu are static JSON files in `data/atkuzu/daily`. The app serves them from there (`DAILY_DIR`), also to its own server-side render, so a new daily needs no rebuild and no restart. `atkuzu-daily` is not a server: `docker compose run --rm atkuzu-daily` writes each missing daily, from the day after the last one up to today in Paris time. Run it every hour (see "Jobs").
- `sifa-page` is not a server. `docker compose run --rm sifa-page` fetches the profile from sifa.id, builds the page and replaces the content of `/var/www/sifa-page`.
- Beszel shows the CPU, RAM, disk and network of the host and of each container, with history and alerts. The hub listens on `127.0.0.1` only: open it with `just beszel-tunnel`. The agent listens on a unix socket, not on a network port, and it connects to the hub itself (see "Monitoring").
- `vmagent` reads the metrics of the targets of `vmagent/scrape.yaml` every 30 seconds: Caddy (the requests of each site) and CrowdSec, on the host. It sends them to a VictoriaMetrics on another server, with the label `machine="hetzner"`. While that server does not answer, it keeps the metrics in `data/vmagent` (1 GB at most), and it sends them later. Its own page (`127.0.0.1:8429`) lists the targets and their state.
- Each container keeps 3 log files of 10 MB at most.

## Local test

Requirements: Docker with Compose 2.24 or later, `just`, `git`.

1. Clone the sources into `src/`:

   ```bash
   just init
   ```

2. Build the images and start the stack. The command waits for the health checks:

   ```bash
   just local-up
   ```

3. Build the static page into `data/www/sifa-page`, and the daily of atkuzu into `data/atkuzu/daily`:

   ```bash
   just local-sifa
   ```

   ```bash
   just local-daily
   ```

   Then connect the local Beszel agent to the local hub:

   ```bash
   just local-beszel
   ```

4. Run the checks. They go through the local Caddy, with the production routes:

   ```bash
   just local-test
   ```

5. Open http://localhost:8080 (site), http://next.localhost:8080 (next-site), http://api.localhost:8080 (vps-back), http://atkuzu.localhost:8080 (atkuzu), http://localhost:8080/sifa-page/ and http://localhost:8091 (Beszel, user `admin@example.com`, password `local-test-password`). The login of atkuzu does not work locally: it needs a public HTTPS domain.

   Locally, vmagent sends the metrics to a VictoriaMetrics of `compose.local.yaml`, on http://localhost:8438 (its UI: http://localhost:8438/vmui). The targets of vmagent are on http://localhost:8429/targets. The target `crowdsec` is down: CrowdSec runs only on the VPS.

6. Stop the stack:

   ```bash
   just local-down
   ```

## Deploy

### On the VPS

The VPS needs:

- Docker with the Compose plugin, usable by the SSH user (member of the `docker` group);
- this repository in `~/hetzner-docker`;
- the env files `env/vps-back.env`, `env/site.env`, `env/atkuzu.env`, `env/atkuzu-daily.env`, `env/beszel.env`, `env/vmagent.env` and, optionally, `env/next-site.env`, made from `env/*.env.example` with the real values;
- the directories `data/vps-back/static`, `data/fonts` and `data/atkuzu` (owned by the uid 1000, the user of the containers);
- Caddy on the host, with a main Caddyfile that imports `managed/*.caddy` (see "Caddy").

### The address of the VPS

This repository does not hold the address of the server. The recipes that reach the VPS read its SSH target from the `VPS` environment variable, and they stop when it is not set. Set it once on the local machine, for example in fish:

```bash
set -Ux VPS deploy@203.0.113.10
```

In bash or zsh, put `export VPS=deploy@203.0.113.10` in the shell profile.

On the VPS itself, `VPS` is not necessary. The recipes find out where they run from the env files: the real `env/*.env` files exist only on the VPS. There, `just publish-sifa`, `just publish-daily`, `just beszel-setup`, `just vps-status` and `just vps-logs` run their command directly, without SSH. The recipes of the build machine (`init`, `pull`, `build`, `local-*`, `send`, `ship`) refuse to run there. To update this repository on the VPS, use `git pull --ff-only`: `just pull` updates the sources of the images, on the build machine.

### Each deploy

On the local machine:

1. `just pull` to update the sources.
2. `just local-up` and `just local-test` to check the new images.
3. `just ship <service>...`, for example `just ship site next-site`. The recipe sends the images and restarts the services on the VPS.

The images have the architecture of the machine that builds them. Build them on a machine with the same architecture as the VPS (arm64 here), or the containers do not start.

`just ship` first tags the images that run on the VPS as `<image>-previous`. To go back to them on the VPS, for example for `site`:

```bash
docker tag tomplanche/portfolio:main-previous tomplanche/portfolio:main && docker compose up -d site
```

### Jobs

The jobs are not servers: each run starts a container, which does its work and stops.

- `just publish-sifa` rebuilds `/var/www/sifa-page` on the VPS. The page shows the sifa.id profile at the time of the build: run the recipe again to show new content.
- `just publish-daily` writes the missing dailies of atkuzu into `data/atkuzu/daily`. A run when the daily of today exists does nothing, so run it every hour with cron on the VPS. Paris is on a whole-hour offset from UTC, so the run at minute 5 of each hour publishes the new daily at 00:05 in Paris, summer time included:

  ```
  5 * * * * cd ~/hetzner-docker && docker compose run --rm atkuzu-daily >> ~/hetzner-docker/data/atkuzu/daily.log 2>&1
  ```

### Monitoring

Beszel needs one setup on the VPS:

1. Set a real email and a strong password in `env/beszel.env`: they make the first user (an admin) at the first start of the hub. Put a value with spaces in quotes. Later, keep this file equal to the login of the hub: `just beszel-setup` logs in with it.
2. Start the hub: `docker compose up -d --wait beszel` on the VPS.
3. Connect the agent: `just beszel-setup`. The recipe logs in to the hub, reads its public key, enables a permanent universal token (or reuses the existing one), writes them to `env/beszel-agent.env`, and starts the agent. The agent then registers itself in the hub. You can run the recipe again: the agent keeps its system.
4. Open the hub from the local machine: `just beszel-tunnel`, then http://localhost:8090.

In the hub, you can set alerts (CPU, RAM, disk, a system that goes down) and back up its data to S3-compatible storage (Settings, Backups).

vmagent sends the other metrics (the requests of each site, CrowdSec) to a VictoriaMetrics on another server. Grafana shows them there. To start it on the VPS:

1. Make `env/vmagent.env` from `env/vmagent.env.example`. Set `remoteWrite_url` to the write URL of VictoriaMetrics, on its private address: `http://<address>:8428/api/v1/write`.
2. For the metrics of each site, the main Caddyfile needs `metrics { per_host }` in its global options. Without it, Caddy gives only its own metrics, not the requests.
3. Update this repository, then start vmagent:

   ```bash
   git pull --ff-only && docker compose up -d --wait vmagent
   ```

4. Check that each target is `up`:

   ```bash
   curl -s http://127.0.0.1:8429/targets
   ```

To add a target, add a job to `vmagent/scrape.yaml`, then restart vmagent: `docker compose restart vmagent`. Never send the port of a target to the internet: a metrics page shows internal data.

### Caddy

`just caddy` installs the sites of `caddy/` in `/etc/caddy/managed/` on the VPS. It replaces all the `*.caddy` files of that directory, and it does not touch the rest of `/etc/caddy`. The main `/etc/caddy/Caddyfile` must import `managed/*.caddy`:

- On a host that runs only this stack, install the minimal one once: `sudo install -m 644 caddy/Caddyfile /etc/caddy/Caddyfile`.
- On a host with other sites, add `import managed/*.caddy` to the main Caddyfile. Keep the other sites out of `managed/`, else `just caddy` removes them. A host name must appear in one file only: a site defined twice stops Caddy at its next reload.

Run `just caddy-diff` on the VPS first, and make sure that the diff shows only the changes that you expect. It compares the routes that Caddy runs (admin API on `localhost:2019`) with the routes after `just caddy`.

## Recipes

| Recipe | Runs on | What it does |
|--------|---------|--------------|
| `just init` | local | Clones the missing sources into `src/`. `next-site` is a git worktree of `src/site` on `next`. |
| `just pull` | local | Updates the sources (fast-forward only). |
| `just build [service...]` | local | Builds the images. |
| `just local-up` | local | Builds and starts the local stack, then waits for the health checks. |
| `just local-test` | local | Checks the local stack through its Caddy. |
| `just local-sifa` | local | Builds the static page into `data/www/sifa-page`. |
| `just local-daily` | local | Writes the missing dailies of atkuzu into `data/atkuzu/daily`. |
| `just local-logs [service...]` | local | Follows the logs of the local stack. |
| `just local-down` | local | Stops the local stack. |
| `just send <service>...` | local | Sends the images to the VPS, without a start. |
| `just ship <service>...` | local | Sends the images and restarts their services on the VPS. |
| `just publish-sifa` | local or VPS | Rebuilds `/var/www/sifa-page` on the VPS. |
| `just publish-daily` | local or VPS | Writes the missing dailies of atkuzu into `data/atkuzu/daily` on the VPS. |
| `just local-beszel` | local | Connects the local Beszel agent to the local hub (port 8091), then starts it. |
| `just beszel-setup` | local or VPS | Connects the Beszel agent to the hub of the VPS, then starts it. |
| `just beszel-tunnel` | local | Opens the Beszel hub of the VPS on http://localhost:8090, through an SSH tunnel. |
| `just vps-status` | local or VPS | `docker compose ps` on the VPS. |
| `just vps-logs [service...]` | local or VPS | Follows the logs on the VPS. |
| `just caddy-diff` | VPS | Compares the routes that Caddy runs with the routes after `just caddy`. |
| `just caddy` | VPS | Installs `caddy/*.caddy` into `/etc/caddy/managed/`, validates and reloads Caddy. It restores the old files on error. |

## Things to know

- A restart of a container stops the app for some seconds. To hide it, add `lb_try_duration 10s` in the `reverse_proxy` blocks of `caddy/`: Caddy then retries during the restart.
- Docker keeps old images. Clean them on the VPS from time to time with `docker image prune`, mostly on a small disk.
- Compose reads `KEY=value` lines in the env files. A value with a `$` must be in single quotes, or Compose replaces the variable.
- `env/*.env` and `data/` hold secrets and files that git does not track. Back them up with the VPS.
