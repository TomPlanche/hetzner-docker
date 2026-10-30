# hetzner-docker: the Docker stack of the Hetzner VPS (vps-back, site,
# next-site, sifa-page) and the config of the Caddy of the host.
#
# [local] recipes run on the build machine: build the images, test them, send
# them to the VPS. The images have the architecture of the build machine: build
# them on a machine with the same architecture as the VPS (arm64 here).
# [vps] recipes run on the VPS, in ~/hetzner-docker.
# [local or vps] recipes act on the stack of the VPS: over SSH from the build
# machine, or directly on the VPS.
#
# The recipes that reach the VPS over SSH read its SSH target from the VPS
# environment variable (user@host). This public repository does not hold the
# address.

# --norc: in an SSH session, `bash -c` reads /etc/bash.bashrc, which fails with
# -u ("PS1: unbound variable").
set shell := ["bash", "--norc", "-euo", "pipefail", "-c"]

vps     := env("VPS", "")
vps_dir := "hetzner-docker"
local   := "docker compose -f compose.yaml -f compose.local.yaml"

# The real env files exist only on the VPS: they tell where a recipe runs.
on_vps := if path_exists(justfile_directory() + "/env/vps-back.env") == "true" { "true" } else { "false" }

# How a [local or vps] recipe runs a command in the stack directory of the VPS:
# directly on the VPS, over SSH elsewhere.
on_stack     := if on_vps == "true" { "bash -c" } else { "ssh " + vps }
on_stack_tty := if on_vps == "true" { "bash -c" } else { "ssh -t " + vps }
stack_dir    := if on_vps == "true" { justfile_directory() } else { vps_dir }

# List the recipes
default:
    @"{{just_executable()}}" --justfile "{{justfile()}}" --list --unsorted

# Clone the missing sources of the images into src/ [local]
init: _build-machine
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p src
    clone() {  # clone <directory> <repository> <branch>
        if [ -e "src/$1" ]; then
            echo "ok     src/$1"
        else
            git clone --quiet --branch "$3" "$2" "src/$1"
            echo "cloned src/$1: $2 on $3"
        fi
    }
    clone vps-back https://github.com/TomPlanche/vps-back.git main
    clone site https://github.com/TomPlanche/portfolio-v222.git main
    clone sifa-page https://github.com/singi-labs/sifa-page.git main
    clone atkuzu https://tangled.org/tomplanche.com/atkuzu main
    # next-site: the next branch of the front, as a git worktree of src/site.
    if [ -e src/next-site ]; then
        echo "ok     src/next-site"
    else
        git -C src/site fetch --quiet origin next
        if git -C src/site show-ref --verify --quiet refs/heads/next; then
            git -C src/site worktree add --quiet "$PWD/src/next-site" next
        else
            git -C src/site worktree add --quiet --track -b next "$PWD/src/next-site" origin/next
        fi
        echo "added  src/next-site: worktree of src/site on next"
    fi

# Update the sources of the images to their upstream branch, force-pushes included [local]
pull: _build-machine
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    dirs=(src/*/)
    if [ "${#dirs[@]}" -eq 0 ]; then
        echo "error: no source in src/, run: just init" >&2
        exit 1
    fi
    # src/ holds mirrors for the builds, not work: each one follows its upstream
    # branch, even after a force-push. A local change stops it, to never lose work.
    failed=0
    for dir in "${dirs[@]}"; do
        echo "== $dir"
        if [ -n "$(git -C "$dir" status --porcelain)" ]; then
            echo "error: $dir has local changes: commit them elsewhere, or drop them" >&2
            failed=$((failed + 1))
            continue
        fi
        git -C "$dir" fetch --quiet
        git -C "$dir" reset --hard --quiet '@{u}'
        git -C "$dir" log --oneline -1
    done
    if [ "$failed" -gt 0 ]; then
        exit 1
    fi

# Build the images: all of them, or the given services [local]
build *services: _build-machine
    #!/usr/bin/env bash
    set -euo pipefail
    # The front shows its last commit: give it to the build (see images/portfolio).
    commit() {  # commit <variable prefix> <source directory>
        local sha
        sha=$(git -C "$2" rev-parse HEAD)
        export "$1_COMMIT_SHA=$sha"
        export "$1_COMMIT_DATE=$(TZ=UTC git -C "$2" log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd)"
        export "$1_COMMIT_URL=https://github.com/TomPlanche/portfolio-v222/commit/$sha"
    }
    commit SITE src/site
    commit NEXT src/next-site
    # With the local file: compose.yaml alone needs env/*.env, which only the VPS
    # has. The images and their names are the same.
    {{local}} --profile tools build {{services}}

# Build and start the stack locally, with Caddy on http://localhost:8080 [local]
local-up: build
    {{local}} up -d --wait --remove-orphans site next-site vps-back atkuzu beszel caddy

# Check the local stack through its Caddy [local]
local-test: _build-machine
    #!/usr/bin/env bash
    set -uo pipefail
    failed=0
    # check <description> <expected HTTP code> <host> <path> [text in the body, or !text not in it] [curl options...]
    check() {
        local description=$1 code=$2 host=$3 path=$4 text=${5:-}
        shift 5 2> /dev/null || shift $#
        local body status
        body=$(curl -sS -m 10 -H "Host: $host" -w '\n%{http_code}' "$@" "http://127.0.0.1:8080$path")
        status=${body##*$'\n'}
        body=${body%$'\n'*}
        if [ "$status" != "$code" ]; then
            echo "FAIL  $description: HTTP $status, expected $code"
            failed=$((failed + 1))
        elif [ "${text#!}" != "$text" ] && grep -qF -- "${text#!}" <<< "$body"; then
            echo "FAIL  $description: \"${text#!}\" in the answer"
            failed=$((failed + 1))
        elif [ -n "$text" ] && [ "${text#!}" = "$text" ] && ! grep -qF -- "$text" <<< "$body"; then
            echo "FAIL  $description: no \"$text\" in the answer"
            failed=$((failed + 1))
        else
            echo "ok    $description"
        fi
    }
    check "site: home page" 200 localhost:8080 / "<html"
    check "site: no maintenance (env/site.env)" 200 localhost:8080 / "!Working on cleaner deployment methods"
    check "site: static file" 200 localhost:8080 /_app/version.json '"version"'
    check "site: sitemap with the last commit" 200 localhost:8080 /sitemap.xml "<lastmod>"
    # The maintenance page answers 503 on purpose (src/hooks.server.ts of the front).
    check "next-site: maintenance from env/next-site.env" 503 next.localhost:8080 / "Working on cleaner deployment methods"
    check "vps-back: root through /api/" 200 localhost:8080 /api/ "Hello"
    check "vps-back: api subdomain" 200 api.localhost:8080 / "Hello"
    # A file in the mounted static directory, served under /static/.
    mkdir -p data/vps-back/static
    echo "local test of /static/" > data/vps-back/static/local-test.txt
    check "vps-back: file of data/vps-back/static" 200 api.localhost:8080 /static/local-test.txt "local test of /static/"
    check "vps-back: same file through /api/static/" 200 localhost:8080 /api/static/local-test.txt "local test of /static/"
    check "vps-back: missing static file" 404 api.localhost:8080 /static/missing.txt
    if [ -d data/www/sifa-page ]; then
        check "sifa-page: static page" 200 localhost:8080 /sifa-page/
    else
        echo "skip  sifa-page: run just local-sifa first"
    fi
    check "atkuzu: home page" 200 atkuzu.localhost:8080 / "<html"
    check "atkuzu: static file" 200 atkuzu.localhost:8080 /_app/version.json '"version"'
    check "atkuzu: login page (form action)" 200 atkuzu.localhost:8080 /login "<html"
    if [ -f data/atkuzu/atkuzu.db ]; then
        echo "ok    atkuzu: database in data/atkuzu (migrations at start-up)"
    else
        echo "FAIL  atkuzu: no data/atkuzu/atkuzu.db"
        failed=$((failed + 1))
    fi
    if [ -d data/atkuzu/daily ]; then
        today=$(TZ=Europe/Paris date +%F)
        check "atkuzu: daily index (DAILY_DIR)" 200 atkuzu.localhost:8080 /daily/index.json "$today"
        check "atkuzu: daily of today (DAILY_DIR)" 200 atkuzu.localhost:8080 "/daily/$today.json" '"puzzles"'
        # The page loads the daily during SSR: the server must find the file too,
        # not only the browser through Caddy.
        check "atkuzu: /daily renders the daily of today on the server" 200 atkuzu.localhost:8080 /daily "solutionSha256"
        past=$(ls data/atkuzu/daily | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$' | grep -v "^$today" | sort | tail -n 1)
        if [ -n "$past" ]; then
            check "atkuzu: /daily/${past%.json} renders a past daily on the server" 200 atkuzu.localhost:8080 "/daily/${past%.json}" "solutionSha256"
        fi
    else
        echo "skip  atkuzu dailies: run just local-daily first"
    fi
    # Beszel: the hub answers, and the agent sends data to it.
    if [ -f data/beszel/agent.env ]; then
        if python3 -I - <<'PY'
    import json, sys, time, urllib.request
    hub = "http://127.0.0.1:8091"
    values = dict(line.split("=", 1) for line in open("env/beszel.env.example") if "=" in line and not line.startswith("#"))
    def call(method, path, body=None, token=None):
        headers = {"Content-Type": "application/json", **({"Authorization": token} if token else {})}
        data = json.dumps(body).encode() if body is not None else None
        with urllib.request.urlopen(urllib.request.Request(hub + path, data=data, headers=headers, method=method), timeout=10) as r:
            return json.load(r)
    call("GET", "/api/health")
    token = call("POST", "/api/collections/users/auth-with-password",
                 {"identity": values["USER_EMAIL"].strip(), "password": values["USER_PASSWORD"].strip()})["token"]
    for _ in range(30):
        systems = call("GET", "/api/collections/systems/records", token=token)["items"]
        if any(s["status"] == "up" for s in systems):
            sys.exit(0)
        time.sleep(2)
    print("  systems:", [(s["name"], s["status"]) for s in systems])
    sys.exit(1)
    PY
        then
            echo "ok    beszel: the hub answers, and the agent is up"
        else
            echo "FAIL  beszel: no agent is up in the hub"
            failed=$((failed + 1))
        fi
    else
        echo "skip  beszel agent: run just local-beszel first"
    fi
    if [ "$failed" -gt 0 ]; then
        echo "$failed check(s) failed"
        exit 1
    fi

# Build the sifa-page into data/www/sifa-page, served on localhost:8080/sifa-page/ [local]
local-sifa: _build-machine
    {{local}} run --rm sifa-page

# Write the missing dailies of atkuzu into data/atkuzu/daily [local]
local-daily: _build-machine
    mkdir -p data/atkuzu/daily
    {{local}} run --rm atkuzu-daily

# Connect the local Beszel agent to the local hub, then start it [local]
local-beszel: _build-machine
    bash scripts/beszel-setup.sh http://127.0.0.1:8091 env/beszel.env.example
    {{local}} up -d --wait beszel-agent

# Show the logs of the local stack [local]
local-logs *services: _build-machine
    {{local}} logs -f {{services}}

# Stop the local stack. `just local-down -v` also deletes the local database [local]
local-down *args: _build-machine
    {{local}} --profile tools down --remove-orphans {{args}}

# Send the images of services to the VPS, without a start [local]
send +services: _build-machine _need-vps
    #!/usr/bin/env bash
    set -euo pipefail
    # The production file alone, so that no local-only image (caddy) goes;
    # --no-env-resolution: the env files exist only on the VPS.
    images=$(docker compose --profile tools config --no-env-resolution --images {{services}} | sort -u | tr '\n' ' ')
    echo "sending to {{vps}}: $images"
    # Keep the images that run now as <image>-previous, to go back to them.
    ssh {{vps}} "for image in $images; do if docker image inspect \$image > /dev/null 2>&1; then docker tag \$image \$image-previous; fi; done"
    docker save $images | gzip | ssh {{vps}} 'gunzip | docker load'

# Send the images of services to the VPS and restart them: `just ship site next-site` [local]
ship +services: (send services)
    #!/usr/bin/env bash
    set -euo pipefail
    # sifa-page and atkuzu-daily are jobs, not servers: `just publish-sifa` and
    # `just publish-daily` run them.
    servers=""
    for service in {{services}}; do
        case "$service" in
            sifa-page | atkuzu-daily) ;;
            *) servers="$servers $service" ;;
        esac
    done
    if [ -n "$servers" ]; then
        ssh {{vps}} "cd {{vps_dir}} && docker compose up -d --wait$servers && docker compose ps"
    fi

# Rebuild sifa-page into /var/www/sifa-page on the VPS [local or vps]
publish-sifa: _need-vps
    {{on_stack}} 'cd {{stack_dir}} && docker compose run --rm sifa-page'

# Write the missing dailies of atkuzu into data/atkuzu/daily on the VPS [local or vps]
publish-daily: _need-vps
    {{on_stack}} 'cd {{stack_dir}} && docker compose run --rm atkuzu-daily'

# Connect the Beszel agent to the hub on the VPS, then start it [local or vps]
beszel-setup: _need-vps
    {{on_stack}} 'cd {{stack_dir}} && bash scripts/beszel-setup.sh http://127.0.0.1:8090 env/beszel.env && docker compose up -d --wait beszel-agent'

# Open the Beszel hub of the VPS on http://localhost:8090, through an SSH tunnel [local]
beszel-tunnel: _build-machine _need-vps
    @echo "Beszel: http://localhost:8090 (Ctrl+C closes the tunnel)"
    ssh -N -L 8090:127.0.0.1:8090 {{vps}}

# Show the services on the VPS [local or vps]
vps-status: _need-vps
    {{on_stack}} 'cd {{stack_dir}} && docker compose ps'

# Follow the logs of services on the VPS [local or vps]
vps-logs *services: _need-vps
    {{on_stack_tty}} 'cd {{stack_dir}} && docker compose logs -f --tail 100 {{services}}'

# Compare the config that Caddy runs with the config after `just caddy` [vps]
caddy-diff:
    #!/usr/bin/env bash
    set -euo pipefail
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    # The new config: a copy of /etc/caddy with the files of caddy/ in managed/.
    cp -R /etc/caddy/. "$stage/"
    mkdir -p "$stage/managed"
    rm -f "$stage"/managed/*.caddy
    cp caddy/*.caddy "$stage/managed/"
    # An absolute import would read the live files instead of the staged ones.
    sed -i "s#/etc/caddy/#$stage/#g" "$stage/Caddyfile"
    caddy adapt --config "$stage/Caddyfile" --adapter caddyfile > "$stage/new.json"
    # The running config comes from the admin API: the files on disk can differ
    # from it, for example during a migration.
    if ! curl -fsS http://localhost:2019/config/ > "$stage/live.json"; then
        echo "warning: no admin API on localhost:2019, the diff uses the files of /etc/caddy" >&2
        caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile > "$stage/live.json"
    fi
    "{{just_executable()}}" --justfile "{{justfile()}}" _normalize "$stage/live.json" > "$stage/live.sorted.json"
    "{{just_executable()}}" --justfile "{{justfile()}}" _normalize "$stage/new.json" > "$stage/new.sorted.json"
    if diff -u --label running --label new "$stage/live.sorted.json" "$stage/new.sorted.json"; then
        echo "no difference: Caddy already runs these routes"
    fi

# Install caddy/*.caddy into /etc/caddy/managed/, validate and reload. Restore the old files on error [vps]
caddy:
    #!/usr/bin/env bash
    set -euo pipefail
    # This repository owns /etc/caddy/managed/ only. The main Caddyfile of the
    # host must import it (caddy/Caddyfile is a minimal one).
    if ! grep -qE '^[[:space:]]*import[[:space:]]+(/etc/caddy/)?managed/' /etc/caddy/Caddyfile; then
        echo "error: /etc/caddy/Caddyfile does not import managed/*.caddy" >&2
        echo "On a host without other sites, start from caddy/Caddyfile: sudo install -m 644 caddy/Caddyfile /etc/caddy/Caddyfile" >&2
        exit 1
    fi
    "{{just_executable()}}" --justfile "{{justfile()}}" caddy-diff
    read -r -p "Install this config and reload Caddy? [y/N] " answer
    if [ "$answer" != "y" ]; then
        echo "stopped, nothing changed"
        exit 1
    fi
    backup="/etc/caddy.bak.$(date +%Y%m%d-%H%M%S)"
    sudo cp -a /etc/caddy "$backup"
    restore() {
        echo "error: restoring /etc/caddy from $backup" >&2
        sudo rm -rf /etc/caddy/managed
        sudo cp -a "$backup/." /etc/caddy/
        sudo systemctl reload caddy || true
        exit 1
    }
    sudo install -d -m 755 /etc/caddy/managed
    sudo find /etc/caddy/managed -maxdepth 1 -name '*.caddy' -delete
    sudo install -m 644 caddy/*.caddy /etc/caddy/managed/
    sudo -u caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || restore
    sudo systemctl reload caddy || restore
    echo "Caddy reloaded. The old files are in $backup"

# Print a Caddy JSON config without what changes when the routes do not:
# - the order of the sites: sort the routes by host (a route without a host
#   match stays last) and the certificate names;
# - the group names of `handle` blocks: Caddy numbers them across all the
#   sites, so a new site moves the numbers of the next ones. Number them again
#   inside each site;
# - the `hide` list of file_server: Caddy puts in it the config file that
#   defines the site, and the staged copy is in /tmp.
[private]
_normalize file:
    #!/usr/bin/env bash
    python3 -I -c '
    import json, sys
    def clean(node, groups):
        if isinstance(node, dict):
            if "group" in node:
                node["group"] = groups.setdefault(node["group"], "group" + str(len(groups)))
            if node.get("handler") == "file_server":
                node.pop("hide", None)
            for value in node.values():
                clean(value, groups)
        elif isinstance(node, list):
            for value in node:
                clean(value, groups)
    config = json.load(open(sys.argv[1]))
    for server in config.get("apps", {}).get("http", {}).get("servers", {}).values():
        server.get("routes", []).sort(key=lambda route: json.dumps(route.get("match"), sort_keys=True))
        for route in server.get("routes", []):
            clean(route, {})
    for policy in config.get("apps", {}).get("tls", {}).get("automation", {}).get("policies", []):
        policy.get("subjects", []).sort()
    print(json.dumps(config, indent=2, sort_keys=True))
    ' {{quote(file)}}

# Stop on the VPS: the recipe runs on the build machine
[private]
_build-machine:
    #!/usr/bin/env bash
    if [ "{{on_vps}}" = "true" ]; then
        echo "error: this recipe runs on the build machine, not on the VPS (the VPS has env/vps-back.env)." >&2
        echo "To update this repository on the VPS: git pull --ff-only" >&2
        exit 1
    fi

# Stop when VPS is not set on the build machine: this public repository does not hold the address of the server
[private]
_need-vps:
    #!/usr/bin/env bash
    if [ "{{on_vps}}" = "false" ] && [ -z "{{vps}}" ]; then
        echo "error: set VPS to the SSH target of the server (user@host)." >&2
        echo "  bash or zsh: export VPS=deploy@203.0.113.10" >&2
        echo "  fish:        set -Ux VPS deploy@203.0.113.10" >&2
        exit 1
    fi
