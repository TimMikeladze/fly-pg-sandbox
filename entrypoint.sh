#!/bin/bash
set -e

# --- Read password ---
if [ -f /run/secrets/POSTGRES_PASSWORD ]; then
    POSTGRES_PASSWORD=$(cat /run/secrets/POSTGRES_PASSWORD)
    export POSTGRES_PASSWORD
fi

PG_USER="${POSTGRES_USER:-postgres}"

# =============================================================================
# Compute settings from available memory
# =============================================================================

MEMORY_MB="${FLY_VM_MEMORY_MB:-256}"

clamp() { local v=$2; [ "$v" -lt "$1" ] && v=$1; [ "$v" -gt "$3" ] && v=$3; echo "$v"; }

# -- PostgreSQL --

# shared_buffers: 12.5% for <=512MB (OS needs breathing room), 25% for larger
if [ "$MEMORY_MB" -le 512 ]; then
    PG_SHARED_BUFFERS=$(clamp 16 $((MEMORY_MB / 8)) 1024)
    PG_EFFECTIVE_CACHE=$(clamp 32 $((MEMORY_MB / 4)) 4096)
    PG_MAINT_WORK_MEM=$(clamp 8 $((MEMORY_MB / 32)) 512)
else
    PG_SHARED_BUFFERS=$(clamp 16 $((MEMORY_MB / 4)) 1024)
    PG_EFFECTIVE_CACHE=$(clamp 32 $((MEMORY_MB * 3 / 4)) 4096)
    PG_MAINT_WORK_MEM=$(clamp 8 $((MEMORY_MB / 16)) 512)
fi

PG_WORK_MEM=$(clamp 1 $((MEMORY_MB / 256)) 64)
PG_WAL_BUFFERS=$(clamp 1 $((PG_SHARED_BUFFERS / 32)) 16)
PG_MAX_WAL=$(clamp 64 "$MEMORY_MB" 2048)
PG_MIN_WAL=$(clamp 32 $((PG_MAX_WAL / 4)) 512)
PG_MAX_CONN=$(clamp 10 $((MEMORY_MB / 16)) 300)

# Parallel query: disabled for <=512MB (saves memory, no benefit on shared CPU)
if [ "$MEMORY_MB" -le 512 ]; then
    PG_PARALLEL_GATHER=0
    PG_PARALLEL_WORKERS=0
    PG_PARALLEL_MAINT=0
    PG_WORKER_PROCS=2
elif [ "$MEMORY_MB" -le 1024 ]; then
    PG_PARALLEL_GATHER=1
    PG_PARALLEL_WORKERS=2
    PG_PARALLEL_MAINT=1
    PG_WORKER_PROCS=4
else
    PG_PARALLEL_GATHER=2
    PG_PARALLEL_WORKERS=4
    PG_PARALLEL_MAINT=1
    PG_WORKER_PROCS=4
fi

# Autovacuum: 1 worker for <=1GB, 2 for larger
if [ "$MEMORY_MB" -le 1024 ]; then
    PG_AV_WORKERS=1
    PG_AV_COST_LIMIT=200
else
    PG_AV_WORKERS=2
    PG_AV_COST_LIMIT=400
fi

# -- PgBouncer --

PGB_POOL=$(clamp 2 $((PG_MAX_CONN / 3)) 50)
PGB_RESERVE=$(clamp 1 $((PGB_POOL / 2)) 5)
# Keep no idle server connections per pool.
#
# PgBouncer's limits are per (user, database) pair but PostgreSQL's
# max_connections is global, and this box hosts a database per project. A
# min_pool_size above zero means every database that has ever been touched pins
# that many server connections open forever, so the global budget drains to
# nothing without a single query running — with a dozen sandbox databases that
# was enough on its own to hand out `53300 sorry, too many clients already`.
# At zero, an idle pool releases after server_idle_timeout and reopens on demand;
# the cost is one connection setup on the first query after a quiet minute.
PGB_MIN_POOL=0
PGB_MAX_DB=$(clamp 5 $((PG_MAX_CONN * 2 / 3)) 200)
PGB_MAX_CLIENT=$(clamp 50 $((PG_MAX_CONN * 8)) 1000)

echo "=== fly-pg-sandbox: ${MEMORY_MB}MB ==="
echo "  PG:  shared_buffers=${PG_SHARED_BUFFERS}MB effective_cache=${PG_EFFECTIVE_CACHE}MB"
echo "  PG:  work_mem=${PG_WORK_MEM}MB maint_mem=${PG_MAINT_WORK_MEM}MB max_conn=${PG_MAX_CONN}"
echo "  PG:  parallel_gather=${PG_PARALLEL_GATHER} workers=${PG_WORKER_PROCS} autovacuum=${PG_AV_WORKERS}"
echo "  PGB: pool=${PGB_POOL} reserve=${PGB_RESERVE} max_db=${PGB_MAX_DB} max_client=${PGB_MAX_CLIENT}"
echo ""

# =============================================================================
# Generate pgbouncer.ini
# =============================================================================

cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
* = host=/var/run/postgresql port=5432

[pgbouncer]
listen_addr = *
listen_port = 6432
unix_socket_dir = /var/run/pgbouncer

; Authentication
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

; Pool settings (auto-tuned for ${MEMORY_MB}MB)
pool_mode = transaction
default_pool_size = ${PGB_POOL}
min_pool_size = ${PGB_MIN_POOL}
reserve_pool_size = ${PGB_RESERVE}
reserve_pool_timeout = 3

; Connection limits
max_client_conn = ${PGB_MAX_CLIENT}
max_db_connections = ${PGB_MAX_DB}

; Timeouts
server_idle_timeout = 60
; Reap pooled client connections that have gone quiet. Serverless runtimes keep
; sockets open between invocations, so without this a client that was frozen or
; torn down mid-connection leaves its half open here indefinitely.
client_idle_timeout = 600
; A client that connects and never finishes logging in is wedged, not slow. The
; 60s default pins the slot for a minute per attempt, which a retrying
; serverless caller turns into a pile of dead connections in seconds.
client_login_timeout = 15
query_timeout = 0
query_wait_timeout = 120
server_connect_timeout = 15

; Notice peers that vanished without sending a FIN — the Fly proxy dropping its
; backhaul, or a machine stop, both look like a live socket to the kernel until
; something probes it. The OS default only starts probing after ~2 hours, which
; is long enough for every client pool to fill with corpses. This detects a dead
; peer in roughly 60 + 15*3 seconds instead.
tcp_keepalive = 1
tcp_keepidle = 60
tcp_keepintvl = 15
tcp_keepcnt = 3

; Low memory settings
pkt_buf = 4096

; Logging
log_connections = 0
log_disconnections = 0
log_pooler_errors = 1
stats_period = 60

; Admin
admin_users = postgres
stats_users = postgres
EOF

# =============================================================================
# Start services
# =============================================================================

mkdir -p /var/run/postgresql /var/run/pgbouncer
chown postgres:postgres /var/run/postgresql /var/run/pgbouncer
chown postgres:postgres /var/lib/postgresql/data
chown postgres:postgres /etc/pgbouncer/pgbouncer.ini

# --- Start Postgres ---
su-exec postgres /usr/local/bin/docker-entrypoint.sh postgres \
    -c shared_buffers=${PG_SHARED_BUFFERS}MB \
    -c effective_cache_size=${PG_EFFECTIVE_CACHE}MB \
    -c work_mem=${PG_WORK_MEM}MB \
    -c maintenance_work_mem=${PG_MAINT_WORK_MEM}MB \
    -c wal_buffers=${PG_WAL_BUFFERS}MB \
    -c max_connections=${PG_MAX_CONN} \
    -c huge_pages=off \
    -c max_wal_size=${PG_MAX_WAL}MB \
    -c min_wal_size=${PG_MIN_WAL}MB \
    -c checkpoint_completion_target=0.9 \
    -c checkpoint_timeout=10min \
    -c random_page_cost=1.1 \
    -c effective_io_concurrency=200 \
    -c default_statistics_target=100 \
    -c max_worker_processes=${PG_WORKER_PROCS} \
    -c max_parallel_workers_per_gather=${PG_PARALLEL_GATHER} \
    -c max_parallel_workers=${PG_PARALLEL_WORKERS} \
    -c max_parallel_maintenance_workers=${PG_PARALLEL_MAINT} \
    -c autovacuum=on \
    -c autovacuum_max_workers=${PG_AV_WORKERS} \
    -c autovacuum_naptime=60s \
    -c autovacuum_vacuum_cost_limit=${PG_AV_COST_LIMIT} \
    -c autovacuum_vacuum_scale_factor=0.1 \
    -c autovacuum_analyze_scale_factor=0.05 \
    -c log_min_duration_statement=1000 \
    -c log_checkpoints=on \
    -c log_connections=off \
    -c log_disconnections=off \
    -c log_lock_waits=on \
    -c log_temp_files=0 \
    -c track_activities=on \
    -c track_counts=on \
    -c track_io_timing=on \
    -c shared_preload_libraries='pg_stat_statements' \
    -c pg_stat_statements.max=1000 \
    -c pg_stat_statements.track=top \
    -c compute_query_id=on &

PG_PID=$!

# Wait for postgres to be ready
echo "Waiting for PostgreSQL to start..."
for i in $(seq 1 30); do
    if su-exec postgres pg_isready -h /var/run/postgresql -U "$PG_USER" > /dev/null 2>&1; then
        echo "PostgreSQL is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "PostgreSQL failed to start within 30 seconds."
        exit 1
    fi
    sleep 1
done

# --- Generate pgbouncer userlist with SCRAM hash ---
SCRAM_HASH=$(su-exec postgres psql -h /var/run/postgresql -U "$PG_USER" -d "${POSTGRES_DB:-testdb}" -tAc \
    "SELECT rolpassword FROM pg_authid WHERE rolname = current_user")

echo "\"$PG_USER\" \"$SCRAM_HASH\"" > /etc/pgbouncer/userlist.txt
chown postgres:postgres /etc/pgbouncer/userlist.txt
chmod 600 /etc/pgbouncer/userlist.txt

# --- Start PgBouncer ---
echo "Starting PgBouncer..."
su-exec postgres /usr/bin/pgbouncer /etc/pgbouncer/pgbouncer.ini &
PGBOUNCER_PID=$!

# --- Watchdog ---
#
# fly.toml checks can only be tcp or http, and a TCP connect to 6432 proves
# nothing beyond "the port is bound". The failure worth catching is a pooler
# that accepts the socket and then never answers the startup packet, which a
# port check reports as healthy while every client hangs.
#
# So probe it the way a client does and, if it stops answering, kill PgBouncer.
# That drops through to the wait below and exits the container, and Fly restarts
# the machine. Three consecutive failures are required so a single slow probe
# under load does not cycle a healthy database.
(
    # Give PgBouncer a moment to bind before the first probe counts.
    for _ in $(seq 1 20); do
        /healthcheck.sh 2>/dev/null && break
        sleep 1
    done

    failures=0
    while sleep 15; do
        if /healthcheck.sh 2>/dev/null; then
            failures=0
            continue
        fi
        failures=$((failures + 1))
        echo "Health probe failed (${failures}/3)."
        if [ "$failures" -ge 3 ]; then
            echo "PgBouncer stopped answering; exiting so Fly restarts the machine."
            # SIGKILL after a grace period: a wedged or stopped process never
            # acts on SIGTERM, and leaving it alive is the state being escaped.
            kill -TERM "$PGBOUNCER_PID" 2>/dev/null
            sleep 5
            kill -KILL "$PGBOUNCER_PID" 2>/dev/null
            exit 1
        fi
    done
) &
WATCHDOG_PID=$!

# Wait for either process to exit
wait -n $PG_PID $PGBOUNCER_PID
EXIT_CODE=$?

kill $WATCHDOG_PID 2>/dev/null
kill $PG_PID $PGBOUNCER_PID 2>/dev/null
wait $PG_PID $PGBOUNCER_PID 2>/dev/null
exit $EXIT_CODE
