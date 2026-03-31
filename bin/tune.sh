#!/bin/bash
# Preview or apply PostgreSQL + PgBouncer settings for a given memory size.
# This mirrors the formulas in entrypoint.sh — entrypoint.sh is the runtime
# source of truth, this updates the config files that feed into it.

set -e

clamp() { local v=$2; [ "$v" -lt "$1" ] && v=$1; [ "$v" -gt "$3" ] && v=$3; echo "$v"; }

compute() {
    local mem=$1

    if [ "$mem" -le 512 ]; then
        sb=$(clamp 16 $((mem / 8)) 1024)
        ec=$(clamp 32 $((mem / 4)) 4096)
        mw=$(clamp 8 $((mem / 32)) 512)
    else
        sb=$(clamp 16 $((mem / 4)) 1024)
        ec=$(clamp 32 $((mem * 3 / 4)) 4096)
        mw=$(clamp 8 $((mem / 16)) 512)
    fi
    wm=$(clamp 1 $((mem / 256)) 64)
    wb=$(clamp 1 $((sb / 32)) 16)
    mwal=$(clamp 64 "$mem" 2048)
    mwalmin=$(clamp 32 $((mwal / 4)) 512)
    mc=$(clamp 10 $((mem / 16)) 300)

    if [ "$mem" -le 512 ]; then pg=0; pw=0; pm=0; wp=2
    elif [ "$mem" -le 1024 ]; then pg=1; pw=2; pm=1; wp=4
    else pg=2; pw=4; pm=1; wp=4; fi

    if [ "$mem" -le 1024 ]; then av=1; ac=200; else av=2; ac=400; fi

    pp=$(clamp 2 $((mc / 3)) 50)
    pr=$(clamp 1 $((pp / 2)) 5)
    md=$(clamp 5 $((mc * 2 / 3)) 200)
    mx=$(clamp 50 $((mc * 8)) 1000)
}

print_one() {
    local mem=$1
    compute "$mem"

    echo "=== ${mem}MB ==="
    echo ""
    printf "  %-28s %s\n" "shared_buffers" "${sb}MB"
    printf "  %-28s %s\n" "effective_cache_size" "${ec}MB"
    printf "  %-28s %s\n" "work_mem" "${wm}MB"
    printf "  %-28s %s\n" "maintenance_work_mem" "${mw}MB"
    printf "  %-28s %s\n" "wal_buffers" "${wb}MB"
    printf "  %-28s %s\n" "max_wal_size" "${mwal}MB"
    printf "  %-28s %s\n" "min_wal_size" "${mwalmin}MB"
    printf "  %-28s %s\n" "max_connections" "$mc"
    printf "  %-28s %s\n" "max_parallel_workers_gather" "$pg"
    printf "  %-28s %s\n" "max_parallel_workers" "$pw"
    printf "  %-28s %s\n" "max_worker_processes" "$wp"
    printf "  %-28s %s\n" "autovacuum_max_workers" "$av"
    echo ""
    printf "  %-28s %s\n" "pgb default_pool_size" "$pp"
    printf "  %-28s %s\n" "pgb reserve_pool_size" "$pr"
    printf "  %-28s %s\n" "pgb max_db_connections" "$md"
    printf "  %-28s %s\n" "pgb max_client_conn" "$mx"
    echo ""
}

print_table() {
    local tiers=("256" "512" "1024" "2048" "4096")
    printf "  %-28s" ""
    for t in "${tiers[@]}"; do printf "  %6sMB" "$t"; done
    echo ""
    printf "  %-28s" ""
    for t in "${tiers[@]}"; do printf "  %8s" "--------"; done
    echo ""

    for label in shared_buffers effective_cache_size work_mem maintenance_work_mem \
                 wal_buffers max_wal_size min_wal_size max_connections parallel_gather \
                 worker_processes autovacuum_workers "" \
                 pgb_pool pgb_reserve pgb_max_db pgb_max_client; do

        if [ -z "$label" ]; then
            echo ""
            continue
        fi

        printf "  %-28s" "$label"
        for t in "${tiers[@]}"; do
            compute "$t"
            case "$label" in
                shared_buffers)       printf "  %6sMB" "$sb" ;;
                effective_cache_size) printf "  %6sMB" "$ec" ;;
                work_mem)             printf "  %6sMB" "$wm" ;;
                maintenance_work_mem) printf "  %6sMB" "$mw" ;;
                wal_buffers)          printf "  %6sMB" "$wb" ;;
                max_wal_size)         printf "  %6sMB" "$mwal" ;;
                min_wal_size)         printf "  %6sMB" "$mwalmin" ;;
                max_connections)      printf "  %8s" "$mc" ;;
                parallel_gather)     printf "  %8s" "$pg" ;;
                worker_processes)     printf "  %8s" "$wp" ;;
                autovacuum_workers)   printf "  %8s" "$av" ;;
                pgb_pool)             printf "  %8s" "$pp" ;;
                pgb_reserve)          printf "  %8s" "$pr" ;;
                pgb_max_db)           printf "  %8s" "$md" ;;
                pgb_max_client)       printf "  %8s" "$mx" ;;
            esac
        done
        echo ""
    done
}

apply_settings() {
    local mem=$1

    if [ ! -f fly.toml ]; then
        echo "Error: fly.toml not found in current directory"; exit 1
    fi
    if [ ! -f docker-compose.yml ]; then
        echo "Error: docker-compose.yml not found in current directory"; exit 1
    fi

    # fly.toml: [vm] memory + [env] FLY_VM_MEMORY_MB
    sed -i.bak "/^\[vm\]/,/^\[/ s/memory = .*/memory = $mem/" fly.toml
    sed -i.bak "s/FLY_VM_MEMORY_MB = .*/FLY_VM_MEMORY_MB = \"$mem\"/" fly.toml
    rm -f fly.toml.bak

    # docker-compose.yml: FLY_VM_MEMORY_MB + mem_limit
    sed -i.bak "s/FLY_VM_MEMORY_MB: .*/FLY_VM_MEMORY_MB: \"$mem\"/" docker-compose.yml
    sed -i.bak "s/mem_limit: .*/mem_limit: ${mem}m/" docker-compose.yml
    rm -f docker-compose.yml.bak

    echo "Updated:"
    echo "  fly.toml           → memory = $mem, FLY_VM_MEMORY_MB = \"$mem\""
    echo "  docker-compose.yml → FLY_VM_MEMORY_MB = \"$mem\", mem_limit = ${mem}m"
    echo ""
    echo "Next steps:"
    echo "  Local:  make down && make up"
    echo "  Fly.io: fly scale memory $mem && fly deploy"
}

# --- Parse args ---

MEMORY=""
APPLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --apply) APPLY=true; shift ;;
        -h|--help)
            echo "Usage: bin/tune.sh [MEMORY_MB] [--apply]"
            echo ""
            echo "  bin/tune.sh              Show all tiers side-by-side"
            echo "  bin/tune.sh 512          Preview settings for 512MB"
            echo "  bin/tune.sh 512 --apply  Preview + update fly.toml and docker-compose.yml"
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MEMORY="$1"
            else
                echo "Error: unknown argument '$1'"; exit 1
            fi
            shift
            ;;
    esac
done

if [ "$APPLY" = true ] && [ -z "$MEMORY" ]; then
    echo "Error: --apply requires a memory value (e.g., bin/tune.sh 512 --apply)"; exit 1
fi

if [ -n "$MEMORY" ]; then
    print_one "$MEMORY"
    if [ "$APPLY" = true ]; then
        apply_settings "$MEMORY"
    fi
else
    print_table
fi
