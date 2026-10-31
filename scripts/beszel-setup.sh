#!/usr/bin/env bash
# Connects the Beszel agent to the hub, once. It logs in to the hub with its
# first user, reads the public key of the hub, and enables a permanent
# universal token: with it, the agent registers itself on its first connection.
# It writes KEY and TOKEN to env/beszel-agent.env, which the beszel-agent
# service reads.
#
# Usage: scripts/beszel-setup.sh <hub URL> <env file with USER_EMAIL and USER_PASSWORD>
set -euo pipefail

hub=${1:?usage: $0 <hub URL> <env file of the hub>}
credentials=${2:?usage: $0 <hub URL> <env file of the hub>}

# env/ belongs to the user of the deploys. data/beszel/ can belong to root,
# because Docker creates the missing directories of its mounts.
output=env/beszel-agent.env
# A name that ends in .env, so that git ignores it too.
partial=env/beszel-agent.partial.env
trap 'rm -f "$partial"' EXIT

umask 077
python3 -I - "$hub" "$credentials" > "$partial" <<'PY'
import json, sys, urllib.request

hub, credentials = sys.argv[1], sys.argv[2]


def read_env(path):
    """Reads KEY=value lines like Compose does, without running them as shell code."""
    values = {}
    with open(path) as lines:
        for raw in lines:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):]
            key, separator, value = line.partition("=")
            if not separator:
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key.strip()] = value
    return values


def call(method, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = token
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(hub + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


values = read_env(credentials)
missing = [name for name in ("USER_EMAIL", "USER_PASSWORD") if not values.get(name)]
if missing:
    sys.exit(f"error: {', '.join(missing)} is not set in {credentials}")

try:
    auth = call("POST", "/api/collections/users/auth-with-password",
                {"identity": values["USER_EMAIL"], "password": values["USER_PASSWORD"]})
except urllib.error.HTTPError as error:
    sys.exit(f"error: the hub refused the login of {values['USER_EMAIL']} (HTTP {error.code}). "
             f"USER_EMAIL and USER_PASSWORD of {credentials} must be the login of the hub: "
             "the hub creates this user at its first start only.")
token = auth["token"]
key = call("GET", "/api/beszel/info", token=token)["key"]
# Reuse the permanent universal token when it exists. A new token would make
# the agent register again, as a second system: the hub finds the systems of
# an agent by token, then by fingerprint.
universal = call("GET", "/api/beszel/universal-token", token=token)
if not (universal.get("active") and universal.get("permanent")):
    universal = call("POST", "/api/beszel/universal-token", {"enable": 1, "permanent": 1}, token=token)

print("# Written by scripts/beszel-setup.sh: the public key of the hub, and the")
print("# universal token with which the agent registers itself.")
print(f'KEY="{key}"')
print(f"TOKEN={universal['token']}")
PY
mv "$partial" "$output"
echo "wrote $output: the agent can connect to $hub"
