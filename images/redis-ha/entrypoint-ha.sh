#!/bin/sh
# entrypoint-ha.sh — role-aware wrapper around redis:7-alpine.
#
# Reads:
#   REPLICA_INDEX            (required) — 0 = primary, >0 = standby
#   REPLICA_NODES            (required) — comma-separated DNS names
#                              of all replicas in placement order;
#                              [0] is the current primary
#   REDIS_PASSWORD           (required) — auth for clients AND for
#                              standby→primary replication. Same
#                              password serves both via masterauth.
#   REPLICA_PRIMARY_ADDR     (optional) — "<ip>:<host_port>" override
#                              for cross-host replication when the
#                              REPLICA_NODES hostname doesn't resolve
#                              from inside the container (matches the
#                              postgres-ha contract).
#
# Behaviour:
#   REPLICA_INDEX=0 (primary):
#     - Builds redis.conf from /etc/redis-ha/redis.ha.conf + auth.
#     - Starts redis-server. AOF replays on restart for crash safety.
#
#   REPLICA_INDEX>0 (standby):
#     - Builds redis.conf with replicaof <primary-host> <primary-port>
#       + masterauth so the replica can authenticate to the primary.
#     - Standby does NOT need to wait for primary like postgres does
#       (no basebackup) — Redis replicas retry connection on their own
#       and switch into "loading from RDB" once the primary is up.
#
# Why a single image rather than two: the orchestrator picks the role
# at deploy time via REPLICA_INDEX. Mirrors postgres-ha exactly so
# promotion mechanics (orchestrator's promoteCore + DNS flip) are
# uniform across HA primitives.

set -eu

log() { echo "[entrypoint-ha] $*" >&2; }

# ── input validation ─────────────────────────────────────────────────
REPLICA_INDEX="${REPLICA_INDEX:-}"
REPLICA_NODES="${REPLICA_NODES:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

if [ -z "$REPLICA_INDEX" ] || [ -z "$REPLICA_NODES" ] || [ -z "$REDIS_PASSWORD" ]; then
    log "ERROR: REPLICA_INDEX, REPLICA_NODES, REDIS_PASSWORD are required"
    log "  got REPLICA_INDEX='$REPLICA_INDEX' REPLICA_NODES='$REPLICA_NODES' REDIS_PASSWORD=${REDIS_PASSWORD:+set}${REDIS_PASSWORD:-unset}"
    exit 64
fi

# Parse REPLICA_NODES — comma-separated list, [0] is the primary.
PRIMARY_HOST=$(echo "$REPLICA_NODES" | cut -d, -f1)
PRIMARY_PORT=6379

# Cross-host override: orchestrator may inject "<ip>:<host_port>" when
# the bare hostname doesn't resolve from inside the container (same
# escape hatch postgres-ha uses).
if [ -n "${REPLICA_PRIMARY_ADDR:-}" ]; then
    PRIMARY_HOST="${REPLICA_PRIMARY_ADDR%:*}"
    PRIMARY_PORT="${REPLICA_PRIMARY_ADDR##*:}"
fi

DATA_DIR="/data"
HA_CONF="/etc/redis-ha/redis.ha.conf"
RUN_CONF="/tmp/redis.run.conf"

mkdir -p "$DATA_DIR"

log "REPLICA_INDEX=$REPLICA_INDEX REPLICA_NODES=$REPLICA_NODES PRIMARY=$PRIMARY_HOST:$PRIMARY_PORT"

# Base config — same for primary + standby.
cp "$HA_CONF" "$RUN_CONF"
{
    echo ""
    echo "# ── role-specific (entrypoint) ──"
    echo "dir $DATA_DIR"
    echo "requirepass $REDIS_PASSWORD"
    # masterauth needed even on the primary if we're prepared to be
    # demoted to standby later (the new primary will require auth).
    echo "masterauth $REDIS_PASSWORD"
} >> "$RUN_CONF"

# ── primary path ─────────────────────────────────────────────────────
if [ "$REPLICA_INDEX" = "0" ]; then
    log "role=primary"
    log "starting redis-server (config $RUN_CONF)"
    exec redis-server "$RUN_CONF"
fi

# ── standby path ─────────────────────────────────────────────────────
log "role=standby (replica $REPLICA_INDEX, primary=$PRIMARY_HOST:$PRIMARY_PORT)"

{
    echo "replicaof $PRIMARY_HOST $PRIMARY_PORT"
    # replica-announce-ip: tell the primary how to reach this standby
    # by IP rather than auto-detected hostname. Macvlan replicas have
    # routable IPs but their hostname inside the container is the
    # docker container ID — useless to the primary for failover.
    if [ -n "${REPLICA_ANNOUNCE_IP:-}" ]; then
        echo "replica-announce-ip $REPLICA_ANNOUNCE_IP"
        echo "replica-announce-port 6379"
    fi
} >> "$RUN_CONF"

log "starting redis-server as replica (config $RUN_CONF)"
exec redis-server "$RUN_CONF"
