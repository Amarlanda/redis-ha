#!/usr/bin/env bash
# deploy-stack.sh — render redis-ha and push the spec to the cluster
# via deploy-runner /sync-spec, then to /scheduler-job. Idempotent.
#
# Usage:
#   ./bin/deploy-stack.sh           # defaults to "prod"
#   ./bin/deploy-stack.sh prod
#
# Env vars:
#   DEPLOY_HOST           default https://deploy-m3.amarlanda.com
#   DEPLOY_RUNNER_TOKEN   bearer token (required)
#
# Pipeline (mirrors cv-stack):
#   1. render-stack.py allocates IPs (idempotent) + renders the spec
#   2. POST /sync-spec/redis-ha       → Consul KV deploy-runner/services/redis-ha
#   3. POST /scheduler-job/redis-ha   → Consul KV london-scheduler/jobs/redis-ha
#                                       (this is what the reconciler reads)
#   4. POST /register/redis-ha        → home host's local Consul agent
#                                       registers the service catalog entry
#   5. POST /dns-register/redis-ha    → primary.redis-ha.service.london via dns-ucg-svc
#
# The DNS step writes a CNAME-equivalent that points at the current
# primary's IP. On promotion, run bin/promote-redis-ha.sh which flips
# the CNAME target.

set -euo pipefail

stack="${1:-prod}"
deploy_host="${DEPLOY_HOST:-https://deploy-m3.amarlanda.com}"
token="${DEPLOY_RUNNER_TOKEN:-}"

if [[ -z "$token" ]]; then
    echo "error: DEPLOY_RUNNER_TOKEN env var required" >&2
    exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

echo "→ render stack '$stack' (output to $out_dir)"
DEPLOY_HOST="$deploy_host" DEPLOY_RUNNER_TOKEN="$token" \
    python3 "$repo_root/bin/render-stack.py" "$stack" --output-dir "$out_dir"

post() {
    local path="$1"
    local data_arg="$2"
    curl -sf -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        $data_arg \
        "$deploy_host$path"
}

echo
echo "→ POST each rendered spec to /sync-spec (writes Consul KV deploy-runner/services/<name>)"
for f in "$out_dir"/*.json; do
    name=$(basename "$f" .json)
    echo -n "  $name ... "
    if post "/sync-spec/$name" "--data-binary @$f" > /dev/null; then
        echo "ok"
    else
        echo "FAIL" >&2; exit 1
    fi
done

echo
echo "→ POST each name to /scheduler-job (writes london-scheduler/jobs/<name>)"
for f in "$out_dir"/*.json; do
    name=$(basename "$f" .json)
    if ! grep -q '"scheduler_job"\|"replicas"' "$f"; then
        echo "  $name ... (no scheduler_job/replicas — skip)"
        continue
    fi
    echo -n "  $name ... "
    if post "/scheduler-job/$name" "" > /dev/null; then
        echo "ok"
    else
        echo "FAIL" >&2; exit 1
    fi
done

echo
echo "→ POST /register on each home host (writes service catalog entry)"
for f in "$out_dir"/*.json; do
    name=$(basename "$f" .json)
    # For HA jobs (replicas:2), Nodes[] may not be set yet at deploy
    # time; the scheduler self-registers via the auto-register hook on
    # container start. /register here is a best-effort speed-up so the
    # catalog appears immediately. Skip silently if the spec has no
    # `node` field.
    node=$(python3 -c "import json,sys; d=json.load(open('$f')); sj=d.get('scheduler_job') or d; print(sj.get('node',''))")
    if [[ -z "$node" || ! "$node" =~ ^mini-[1-4]$ ]]; then
        echo "  $name ... (no fixed node — scheduler will self-register on start)"
        continue
    fi
    n="${node#mini-}"
    host_url="https://deploy-m${n}.amarlanda.com"
    echo -n "  $name → $host_url ... "
    if curl -sf -X POST -H "Authorization: Bearer $token" "$host_url/register/$name" > /dev/null; then
        echo "ok"
    else
        echo "FAIL (best-effort)"
    fi
done

echo
echo "→ POST /dns-register (writes primary.<svc>.service.london via dns-ucg-svc)"
for f in "$out_dir"/*.json; do
    name=$(basename "$f" .json)
    echo -n "  $name ... "
    if post "/dns-register/$name" "" > /dev/null; then
        echo "ok"
    else
        echo "FAIL (best-effort)"
    fi
done

echo
echo "✓ stack '$stack' fully synced + registered."
