#!/bin/bash
# promote-redis-ha.sh — manual failover for redis-ha. Mirrors
# bin/promote-postgres-ha.sh in ansible-local.
#
# Usage:
#   ./bin/promote-redis-ha.sh <new-primary-short-alias>
#   ./bin/promote-redis-ha.sh mini-1
#
# What it does:
#   1. Verify the named host runs ldn-redis-ha as a STANDBY
#      (INFO replication → role=replica) — refuses to "promote" the
#      already-primary or a host without the container.
#   2. docker exec ldn-redis-ha redis-cli REPLICAOF NO ONE — Redis
#      stops following the primary and accepts writes immediately.
#   3. Verify INFO replication → role=master.
#   4. Print the manual cutover steps for the orchestrator (swap
#      Job.Nodes order so REPLICA_INDEX=0 lands on the new primary
#      next reconcile) + DNS flip.
#
# Caveats:
#   - Old primary needs `REPLICAOF <new-primary> 6379` before it can
#     re-attach. Redis handles the discard-and-resync automatically
#     — much simpler than postgres pg_rewind.
#   - Auto-failover is NOT this script (see Sentinel if needed).
#   - DNS flip: this script only promotes the local Redis. The
#     orchestrator's updateRedisHaPrimaryDNS hook (mirroring postgres-
#     ha's) flips primary.redis-ha.service.london to the new IP on
#     the next reconcile tick when it sees Nodes reordered.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <new-primary-short-alias>" >&2
    echo "  e.g. $0 mini-1" >&2
    exit 64
fi

NEW_PRIMARY="$1"

case "$NEW_PRIMARY" in
    mini-1|m1) IP="10.0.0.11" ;;
    mini-2|m2) IP="10.0.0.22" ;;
    mini-3|m3) IP="10.0.0.33" ;;
    mini-4|m4) IP="10.0.0.44" ;;
    *) echo "unknown alias: $NEW_PRIMARY (expected mini-1..mini-4)" >&2; exit 64 ;;
esac

SSH_PASS="${PULUMI_ADMIN_PASSWORD:-Dragon101}"
SSH_OPTS="-o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10"
ssh_run() {
    sshpass -p "$SSH_PASS" ssh $SSH_OPTS "pulumi-admin@$IP" "$1"
}

echo "[promote] target: $NEW_PRIMARY ($IP)"

# 1. Pre-check: container exists + currently a replica
# Redis-cli needs the password — pull it from the running container's env
# so we don't have to plumb vault here.
ROLE=$(ssh_run '
PASS=$(/opt/homebrew/bin/docker inspect ldn-redis-ha --format "{{range .Config.Env}}{{println .}}{{end}}" 2>/dev/null | grep "^REDIS_PASSWORD=" | cut -d= -f2-)
if [ -z "$PASS" ]; then
    echo "no-password" >&2
    exit 2
fi
/opt/homebrew/bin/docker exec ldn-redis-ha redis-cli -a "$PASS" --no-auth-warning INFO replication 2>/dev/null | grep "^role:" | cut -d: -f2 | tr -d "[:space:]"
' 2>/dev/null)

case "$ROLE" in
    slave|replica)
        echo "[promote] OK: $NEW_PRIMARY is currently a replica — proceeding"
        ;;
    master)
        echo "[promote] ERROR: $NEW_PRIMARY is already master; nothing to promote" >&2
        exit 1
        ;;
    *)
        echo "[promote] ERROR: couldn't determine role (got '$ROLE') — check ldn-redis-ha is running on $NEW_PRIMARY" >&2
        exit 2
        ;;
esac

# 2. Run REPLICAOF NO ONE
echo "[promote] running REPLICAOF NO ONE on $NEW_PRIMARY"
ssh_run '
PASS=$(/opt/homebrew/bin/docker inspect ldn-redis-ha --format "{{range .Config.Env}}{{println .}}{{end}}" | grep "^REDIS_PASSWORD=" | cut -d= -f2-)
/opt/homebrew/bin/docker exec ldn-redis-ha redis-cli -a "$PASS" --no-auth-warning REPLICAOF NO ONE
'

# 3. Verify role flipped
sleep 2
NEW_ROLE=$(ssh_run '
PASS=$(/opt/homebrew/bin/docker inspect ldn-redis-ha --format "{{range .Config.Env}}{{println .}}{{end}}" | grep "^REDIS_PASSWORD=" | cut -d= -f2-)
/opt/homebrew/bin/docker exec ldn-redis-ha redis-cli -a "$PASS" --no-auth-warning INFO replication 2>/dev/null | grep "^role:" | cut -d: -f2 | tr -d "[:space:]"
' 2>/dev/null)
if [ "$NEW_ROLE" != "master" ]; then
    echo "[promote] ERROR: REPLICAOF NO ONE ran but role is still '$NEW_ROLE' (expected 'master')" >&2
    exit 3
fi

echo "[promote] ✓ $NEW_PRIMARY is now master"
echo
echo "Next manual steps (until orchestrator hook lands):"
echo "  1. SSH the OLD primary and demote it:"
echo "     /opt/homebrew/bin/docker exec ldn-redis-ha redis-cli -a <pass> REPLICAOF $IP 6379"
echo "  2. Reorder Job.Nodes so [0]=$NEW_PRIMARY:"
echo "     curl -X POST https://deploy-$NEW_PRIMARY.amarlanda.com/scheduler-job/redis-ha?promote=$NEW_PRIMARY"
echo "  3. Flip DNS: primary.redis-ha.service.london → $IP"
echo "     (orchestrator does this automatically once Job.Nodes is reordered)"
