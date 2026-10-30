#!/usr/bin/env bash
# Connects the Beszel agent to the hub, once. It logs in to the hub with its
# first user, reads the public key of the hub, and enables a permanent
# universal token: with it, the agent registers itself on its first connection.
# It writes KEY and TOKEN to data/beszel/agent.env, which the beszel-agent
# service reads.
#
# Usage: scripts/beszel-setup.sh <hub URL> <env file with USER_EMAIL and USER_PASSWORD>
set -euo pipefail

hub=${1:?usage: $0 <hub URL> <env file of the hub>}
credentials=${2:?usage: $0 <hub URL> <env file of the hub>}

set -a
. "$credentials"
set +a
: "${USER_EMAIL:?is not set in $credentials}" "${USER_PASSWORD:?is not set in $credentials}"

mkdir -p data/beszel
umask 077
python3 -I - "$hub" > data/beszel/agent.env.new <<'PY'
import json, os, sys, urllib.request

hub = sys.argv[1]


def call(method, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = token
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(hub + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


auth = call("POST", "/api/collections/users/auth-with-password",
            {"identity": os.environ["USER_EMAIL"], "password": os.environ["USER_PASSWORD"]})
token = auth["token"]
key = call("GET", "/api/beszel/info", token=token)["key"]
universal = call("POST", "/api/beszel/universal-token", {"enable": 1, "permanent": 1}, token=token)

print("# Written by scripts/beszel-setup.sh: the public key of the hub, and the")
print("# universal token with which the agent registers itself.")
print(f'KEY="{key}"')
print(f"TOKEN={universal['token']}")
PY
mv data/beszel/agent.env.new data/beszel/agent.env
echo "wrote data/beszel/agent.env: the agent can connect to $hub"
