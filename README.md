# redis-ha

Shared, highly-available Redis cluster for the London Mac-Mini fleet.
A single primary + replica pair with manual failover, reachable at
`primary.redis-ha.service.london:6379`.

Mirrors the [postgres-ha](https://github.com/Amarlanda/ansible-local/tree/main/images/postgres-ha)
HA contract: one image, role decided by `REPLICA_INDEX` env var, the
orchestrator handles placement (anti-affinity) and primary-DNS flip
on promotion. Mirrors the [cv-stack](https://github.com/Amarlanda/cv-stack)
deploy scaffolding: templated specs, GitHub Actions sync, n8n-friendly
`repository_dispatch` trigger.

## Why this exists

Apps used to embed their own Redis container per stack (e.g.
`prod-langgraph-redis`, `cv-stack-dev-langgraph-redis`). That's
N copies of the same dependency, no failover, no shared cache, no
single source of truth for Redis backups. This repo replaces that
with one HA cluster every app points at.

## Architecture

```
                ┌──────────────────────────────────┐
                │  primary.redis-ha.service.london │ (DNS, flips on promotion)
                └─────────────┬────────────────────┘
                              ▼
        ┌─────────────────────┴─────────────────────┐
        │                                           │
   ┌────┴────┐  REPLICAOF stream  (RDB+commands)  ┌─┴────┐
   │ primary │  ────────────────────────────────► │ stby │
   │  mini-3 │                                    │ mini-4│
   └─────────┘                                    └──────┘
```

- **Topology**: 1 primary + 1 standby, anti-affinity enforced (the
  scheduler refuses to put both replicas on the same host).
- **Replication**: standby uses `REPLICAOF <primary-ip> 6379`. AOF
  on both for crash safety; standby is read-only (`replica-read-only yes`).
- **Auth**: single `REDIS_PASSWORD` secret used as both `requirepass`
  (clients) and `masterauth` (replication).
- **Persistence**: per-replica AOF at `/Users/pulumi-admin/redis-ha-{0,1}/data`
  on each host. Orchestrator pins replica 0's data dir to the primary
  host so promotions don't lose data.
- **DNS**: `primary.redis-ha.service.london` is a CNAME-equivalent that
  the orchestrator flips to whichever replica is currently the primary.

## Deploy

GitHub Actions auto-deploys `prod` on push to `main` whenever the
spec, stack values, render code, or workflow change. Manual paths:

```bash
# Local (needs DEPLOY_RUNNER_TOKEN env var)
./bin/deploy-stack.sh prod

# Manual via GH Actions UI: workflow "sync to cluster" → run workflow

# Via n8n (example):
curl -X POST -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer <gh-pat>" \
  https://api.github.com/repos/Amarlanda/redis-ha/dispatches \
  -d '{"event_type": "deploy-stack", "client_payload": {"stack": "prod"}}'
```

## Failover

Auto-failover isn't included (no Sentinel — kept simple to mirror the
manual postgres-ha model). Run when a host is going down or has died:

```bash
./bin/promote-redis-ha.sh mini-1   # promote the replica on mini-1
```

The script:
1. Verifies the target host's container is currently a replica
2. Runs `REPLICAOF NO ONE` via `redis-cli`
3. Verifies the new role is `master`
4. Prints the manual cutover steps (orchestrator Job.Nodes reorder + DNS flip)

The orchestrator's `updateRedisHaPrimaryDNS` hook flips
`primary.redis-ha.service.london` automatically once `Job.Nodes` is
reordered (same path postgres-ha takes — see ansible-local's
`bin/promote-postgres-ha.sh`).

## Repo layout

```
redis-ha/
├── bin/
│   ├── deploy-stack.sh          ← render + sync
│   ├── render-stack.py          ← Jinja2 → JSON spec; allocates IPs
│   └── promote-redis-ha.sh      ← manual failover
├── deploy/specs/
│   └── redis-ha.json.j2         ← templated job spec
├── images/redis-ha/
│   ├── Dockerfile               ← FROM redis:7-alpine
│   ├── build.sh                 ← tags + pushes 7-vX.Y.Z
│   ├── entrypoint-ha.sh         ← role-aware (REPLICA_INDEX 0/N)
│   └── redis.ha.conf            ← shared config fragment
├── stacks/
│   └── prod.yaml                ← stack values (nodes, resources, ips)
└── .github/workflows/sync.yml   ← auto-deploy on push to main
```

## Building the image

The image is built+pushed by an n8n `build-docker-image` workflow that
runs on push to `main` whenever `images/redis-ha/**` changes. Manual
path:

```bash
cd images/redis-ha
VERSION=0.1.0 ./build.sh
docker push ghcr.io/amarlanda/redis-ha:7-v0.1.0
docker push ghcr.io/amarlanda/redis-ha:7-latest
```

The version pin in `deploy/specs/redis-ha.json.j2` controls which tag
the cluster runs. Bump it when the entrypoint script or HA config
fragment changes.

## Migrating apps off per-stack Redis

Swap any in-stack Redis URI from
`redis://<stack>-langgraph-redis.home:6379` to
`redis://:<password>@primary.redis-ha.service.london:6379`. The shared
cluster gives you failover + a stable target across stack rebuilds.

For per-tenant isolation, use Redis logical databases (`/0`, `/1`,
…) — Redis supports 16 by default, configurable via `databases N` in
`redis.ha.conf`.
