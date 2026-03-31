#!/bin/bash
set -e

usage() {
    echo "Usage: bin/setup-fly.sh [options]"
    echo ""
    echo "Options:"
    echo "  -n, --name NAME       App name (default: pg-sandbox-RANDOM)"
    echo "  -r, --region REGION   Fly region (default: sjc)"
    echo "  -p, --password PASS   Postgres password (default: auto-generated)"
    echo "  -d, --db NAME         Database name (default: testdb)"
    echo "  -a, --access MODE     Access mode: proxy, ipv6, public (default: proxy)"
    echo "  -c, --cpu CPU         VM size (default: shared-cpu-1x)"
    echo "  -m, --memory MB       Memory in MB (default: 256)"
    echo "  -v, --volume GB       Volume size in GB (default: 1)"
    echo "  -h, --help            Show this help"
    echo ""
    echo "Access modes:"
    echo "  proxy   Internal only, connect via 'fly proxy' (free)"
    echo "  ipv6    Public via IPv6 only (free, requires IPv6 client)"
    echo "  public  Public via dedicated IPv4 + IPv6 (+\$2/mo)"
    echo ""
    echo "VM sizes: shared-cpu-{1,2,4,6,8}x, performance-{1,2,4,6,8,10,12,14,16}x"
    echo ""
    echo "Examples:"
    echo "  bin/setup-fly.sh                                          # interactive"
    echo "  bin/setup-fly.sh -n my-db -r iad                          # internal only"
    echo "  bin/setup-fly.sh -n my-db -r sjc -a public                # public access"
    echo "  bin/setup-fly.sh -n my-db -c shared-cpu-2x -m 512 -v 2   # bigger VM"
    echo "  bin/setup-fly.sh --name my-db --region sjc --access ipv6  # ipv6 only"
    exit 0
}

# Defaults
APP_NAME=""
REGION=""
PG_PASS=""
DB_NAME=""
ACCESS=""
CPU=""
MEMORY=""
VOLUME=""
INTERACTIVE=true

# Parse flags
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)    APP_NAME="$2"; shift 2 ;;
        -r|--region)  REGION="$2"; shift 2 ;;
        -p|--password) PG_PASS="$2"; shift 2 ;;
        -d|--db)      DB_NAME="$2"; shift 2 ;;
        -a|--access)  ACCESS="$2"; shift 2 ;;
        -c|--cpu)     CPU="$2"; shift 2 ;;
        -m|--memory)  MEMORY="$2"; shift 2 ;;
        -v|--volume)  VOLUME="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
    INTERACTIVE=false
done

echo "=== fly-pg-sandbox setup ==="
echo ""

# Check flyctl is installed
if ! command -v fly &> /dev/null; then
    echo "Error: flyctl is not installed."
    echo "Install it: https://fly.io/docs/hands-on/install-flyctl/"
    exit 1
fi

# Check logged in
if ! fly auth whoami &> /dev/null; then
    echo "Not logged in to Fly. Running 'fly auth login'..."
    fly auth login
fi

# Fill in defaults, prompt only if interactive and not set via flags
DEFAULT_APP="pg-sandbox-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
if [ -z "$APP_NAME" ]; then
    if [ "$INTERACTIVE" = true ]; then
        read -p "App name [$DEFAULT_APP]: " APP_NAME
    fi
    APP_NAME="${APP_NAME:-$DEFAULT_APP}"
fi

if [ -z "$REGION" ]; then
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo "Regions:"
        echo "  US:      sjc (San Jose), lax (Los Angeles), ewr (Secaucus NJ),"
        echo "           iad (Ashburn VA), ord (Chicago), dfw (Dallas)"
        echo "  Canada:  yyz (Toronto)"
        echo "  Europe:  ams (Amsterdam), cdg (Paris), fra (Frankfurt),"
        echo "           lhr (London), arn (Stockholm)"
        echo "  Asia:    nrt (Tokyo), sin (Singapore), bom (Mumbai)"
        echo "  Other:   syd (Sydney), gru (São Paulo), jnb (Johannesburg)"
        read -p "Region [sjc]: " REGION
    fi
    REGION="${REGION:-sjc}"
fi

if [ -z "$PG_PASS" ]; then
    PG_PASS=$(openssl rand -base64 24)
    if [ "$INTERACTIVE" = true ]; then
        read -p "Postgres password [$PG_PASS]: " USER_PASS
        PG_PASS="${USER_PASS:-$PG_PASS}"
    fi
fi

if [ -z "$DB_NAME" ]; then
    if [ "$INTERACTIVE" = true ]; then
        read -p "Database name [testdb]: " DB_NAME
    fi
    DB_NAME="${DB_NAME:-testdb}"
fi

if [ -z "$ACCESS" ]; then
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo "Access mode:"
        echo "  1) proxy   - Internal only, connect via 'fly proxy' (free)"
        echo "  2) ipv6    - Public via IPv6 only (free, requires IPv6 client)"
        echo "  3) public  - Public via dedicated IPv4 + IPv6 (+\$2/mo)"
        read -p "Access mode [1]: " ACCESS_CHOICE
        case "$ACCESS_CHOICE" in
            2|ipv6)  ACCESS="ipv6" ;;
            3|public) ACCESS="public" ;;
            *)       ACCESS="proxy" ;;
        esac
    else
        ACCESS="proxy"
    fi
fi

# Validate access mode
case "$ACCESS" in
    proxy|ipv6|public) ;;
    *) echo "Error: invalid access mode '$ACCESS'. Use: proxy, ipv6, public"; exit 1 ;;
esac

if [ -z "$CPU" ]; then
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo "VM size (shared = burstable, performance = dedicated):"
        echo ""
        echo "  Shared:"
        echo "   1) shared-cpu-1x    1 shared   from \$1.94/mo"
        echo "   2) shared-cpu-2x    2 shared   from \$3.89/mo"
        echo "   3) shared-cpu-4x    4 shared   from \$7.78/mo"
        echo "   4) shared-cpu-6x    6 shared   from \$11.66/mo"
        echo "   5) shared-cpu-8x    8 shared   from \$15.55/mo"
        echo ""
        echo "  Performance (dedicated):"
        echo "   6) performance-1x    1 CPU   from \$31/mo"
        echo "   7) performance-2x    2 CPU   from \$62/mo"
        echo "   8) performance-4x    4 CPU   from \$124/mo"
        echo "   9) performance-6x    6 CPU   from \$186/mo"
        echo "  10) performance-8x    8 CPU   from \$248/mo"
        echo "  11) performance-10x  10 CPU   from \$310/mo"
        echo "  12) performance-12x  12 CPU   from \$372/mo"
        echo "  13) performance-14x  14 CPU   from \$434/mo"
        echo "  14) performance-16x  16 CPU   from \$496/mo"
        echo ""
        read -p "VM size [1]: " CPU_CHOICE
        case "$CPU_CHOICE" in
            2)  CPU="shared-cpu-2x" ;;
            3)  CPU="shared-cpu-4x" ;;
            4)  CPU="shared-cpu-6x" ;;
            5)  CPU="shared-cpu-8x" ;;
            6)  CPU="performance-1x" ;;
            7)  CPU="performance-2x" ;;
            8)  CPU="performance-4x" ;;
            9)  CPU="performance-6x" ;;
            10) CPU="performance-8x" ;;
            11) CPU="performance-10x" ;;
            12) CPU="performance-12x" ;;
            13) CPU="performance-14x" ;;
            14) CPU="performance-16x" ;;
            *)  CPU="shared-cpu-1x" ;;
        esac
    else
        CPU="shared-cpu-1x"
    fi
fi

# Validate CPU
case "$CPU" in
    shared-cpu-1x|shared-cpu-2x|shared-cpu-4x|shared-cpu-6x|shared-cpu-8x) ;;
    performance-1x|performance-2x|performance-4x|performance-6x|performance-8x) ;;
    performance-10x|performance-12x|performance-14x|performance-16x) ;;
    *) echo "Error: invalid VM size '$CPU'."; exit 1 ;;
esac

if [ -z "$MEMORY" ]; then
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo "Memory (MB):"
        echo "  256  - Minimum (~15 connections)"
        echo "  512  - Comfortable (~30 connections)"
        echo "  1024 - Plenty (~60 connections)"
        echo "  2048 - Heavy workloads (~128 connections)"
        read -p "Memory in MB [256]: " MEMORY
    fi
    MEMORY="${MEMORY:-256}"
fi

# Validate memory is a number
if ! [[ "$MEMORY" =~ ^[0-9]+$ ]]; then
    echo "Error: memory must be a number in MB (e.g., 256, 512, 1024)"; exit 1
fi

if [ -z "$VOLUME" ]; then
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo "Volume size (GB):"
        echo "  1  - Small projects"
        echo "  5  - Multiple databases"
        echo "  10 - Larger datasets"
        echo "  20 - Heavy use"
        read -p "Volume size in GB [1]: " VOLUME
    fi
    VOLUME="${VOLUME:-1}"
fi

# Validate volume is a number
if ! [[ "$VOLUME" =~ ^[0-9]+$ ]]; then
    echo "Error: volume must be a number in GB (e.g., 1, 5, 10)"; exit 1
fi

echo ""
echo "=== Creating Fly app: $APP_NAME ==="
fly apps create "$APP_NAME"

# Update fly.toml
sed -i.bak "s/^app = .*/app = \"$APP_NAME\"/" fly.toml
sed -i.bak "s/^primary_region = .*/primary_region = \"$REGION\"/" fly.toml
sed -i.bak "s/POSTGRES_DB = .*/POSTGRES_DB = \"$DB_NAME\"/" fly.toml
sed -i.bak "s/FLY_VM_MEMORY_MB = .*/FLY_VM_MEMORY_MB = \"$MEMORY\"/" fly.toml
sed -i.bak "/^\[vm\]/,/^\[/ s/size = .*/size = \"$CPU\"/" fly.toml
sed -i.bak "/^\[vm\]/,/^\[/ s/memory = .*/memory = $MEMORY/" fly.toml
rm -f fly.toml.bak

echo ""
echo "=== Creating ${VOLUME}GB volume in $REGION ==="
fly volumes create pg_data --size "$VOLUME" --region "$REGION" --app "$APP_NAME" --yes

echo ""
echo "=== Setting secrets ==="
fly secrets set POSTGRES_PASSWORD="$PG_PASS" --app "$APP_NAME"

# Allocate IPs based on access mode
if [ "$ACCESS" = "ipv6" ] || [ "$ACCESS" = "public" ]; then
    echo ""
    echo "=== Allocating IPs ==="
    fly ips allocate-v6 --app "$APP_NAME"
    if [ "$ACCESS" = "public" ]; then
        fly ips allocate-v4 --app "$APP_NAME" --yes
    fi
fi

echo ""
echo "=== Deploying ==="
fly deploy --app "$APP_NAME"

# Get allocated IP for output
PUBLIC_IP=""
if [ "$ACCESS" = "public" ]; then
    PUBLIC_IP=$(fly ips list --app "$APP_NAME" --json 2>/dev/null | \
        python3 -c "import json,sys; ips=json.load(sys.stdin); print(next((i['Address'] for i in ips if i['Version']=='v4'), ''))" 2>/dev/null || true)
fi
IPV6_IP=""
if [ "$ACCESS" = "ipv6" ] || [ "$ACCESS" = "public" ]; then
    IPV6_IP=$(fly ips list --app "$APP_NAME" --json 2>/dev/null | \
        python3 -c "import json,sys; ips=json.load(sys.stdin); print(next((i['Address'] for i in ips if i['Version']=='v6'), ''))" 2>/dev/null || true)
fi

echo ""
echo "=== Done! ==="
echo ""
echo "  App:      $APP_NAME"
echo "  Region:   $REGION"
echo "  Database: $DB_NAME"
echo "  Password: $PG_PASS"
echo "  Access:   $ACCESS"
echo "  VM:       $CPU / ${MEMORY}MB"
echo "  Volume:   ${VOLUME}GB"
echo ""

case "$ACCESS" in
    proxy)
        echo "  Connect (via proxy):"
        echo "    fly proxy 5432:6432 --app $APP_NAME"
        echo "    psql \"postgres://postgres:${PG_PASS}@localhost:5432/${DB_NAME}\""
        ;;
    ipv6)
        echo "  Connect (IPv6):"
        if [ -n "$IPV6_IP" ]; then
            echo "    psql \"postgres://postgres:${PG_PASS}@[${IPV6_IP}]:5432/${DB_NAME}\""
        fi
        echo "    psql \"postgres://postgres:${PG_PASS}@${APP_NAME}.fly.dev:5432/${DB_NAME}\""
        echo ""
        echo "  Note: Requires IPv6 connectivity on the client."
        ;;
    public)
        echo "  Connect (public):"
        if [ -n "$PUBLIC_IP" ]; then
            echo "    psql \"postgres://postgres:${PG_PASS}@${PUBLIC_IP}:5432/${DB_NAME}\""
        fi
        echo "    psql \"postgres://postgres:${PG_PASS}@${APP_NAME}.fly.dev:5432/${DB_NAME}\""
        echo ""
        echo "  Cost: +\$2/mo for dedicated IPv4"
        ;;
esac

echo ""
echo "  Internal (from Fly apps):"
echo "    postgres://postgres:${PG_PASS}@${APP_NAME}.internal:6432/${DB_NAME}"
echo ""
echo "  Save your password somewhere safe!"
