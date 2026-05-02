# redis-ha — redis:7-alpine wrapped with a role-aware entrypoint
# that branches on REPLICA_INDEX:
#   0     → primary: standalone redis-server with AOF + auth
#   1..N  → standby: --replicaof <primary-host> <primary-port>
#
# The orchestrator (mission-control-ha-plan §10) injects REPLICA_INDEX
# and REPLICA_NODES env vars per replica at deploy time. Image is
# completely orchestrator-agnostic — same D7 contract postgres-ha
# uses, so promotion + DNS flip mechanics are identical.
#
# Build: ./build.sh   (or  docker build -t redis-ha:7-v0.1.0 .)

FROM redis:7-alpine

# Static config fragment + entrypoint live under /etc/redis-ha/.
# Kept separate from the data dir (/data) so they survive when the
# data dir is wiped (rare for Redis — only on AOF corruption, but the
# pattern matches postgres-ha's separation).
RUN mkdir -p /etc/redis-ha
COPY redis.ha.conf       /etc/redis-ha/redis.ha.conf
COPY entrypoint-ha.sh    /usr/local/bin/entrypoint-ha.sh
RUN chmod +x /usr/local/bin/entrypoint-ha.sh

# Replace the upstream entrypoint with our wrapper. The wrapper does
# role detection + builds the redis.conf, then exec's redis-server
# with the merged config (so signals + PID 1 semantics work cleanly).
ENTRYPOINT ["/usr/local/bin/entrypoint-ha.sh"]
CMD ["redis-server"]
