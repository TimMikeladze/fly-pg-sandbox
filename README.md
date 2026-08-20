# fly-pg-sandbox

A disposable, minimal PostgreSQL for when you need a real database but don't want to pay for managed services. Perfect for dev, testing, hobby projects, side projects, and throwaway environments. Treat it as pseudo-ephemeral — cheap enough to spin up and tear down without a second thought.

**Not for production.** If you need HA, replication, or backups, use [Neon](https://neon.tech), [Supabase](https://supabase.com), or [Fly Managed Postgres](https://fly.io/docs/postgres/).

PostgreSQL 16 + PgBouncer on Fly.io. Configurable VM, memory, and volume. Auto-stops when idle, auto-starts on connection.

**Cost:** Dedicated IPv4 is +$2/mo (optional). See [Fly.io pricing](https://fly.io/pricing) for VM and volume costs. With auto-stop and the smallest VM, you're looking at pennies.

> **No High Availability.** Single machine, single volume, no replication.
> Data is safe on the volume, but there will be downtime if the machine restarts.

---

## Quick Start

```bash
make deploy       # create + deploy to Fly.io (interactive)
make destroy      # tear it all down when done
make help         # show all commands
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Fly.io Machine                          │
│            (default: shared-cpu-1x / 256MB / 1GB vol)       │
│                                                             │
│  ┌─────────────┐              ┌────────────────────────┐   │
│  │  PgBouncer  │─────────────▶│      PostgreSQL 16     │   │
│  │  :6432      │  unix socket │      :5432             │   │
│  │             │              │                        │   │
│  │ auto-tuned  │              │ 13 extensions          │   │
│  │ pool sizes  │              │ SCRAM-SHA-256 auth     │   │
│  └─────────────┘              │ auto-tuned settings    │   │
│        ▲                      └────────────────────────┘   │
│        │                                │                   │
│   port 5432 (external)          ┌───────┴──────┐           │
│   port 6432 (Fly internal)      │    Volume    │           │
│                                 └──────────────┘           │
│  All settings computed from FLY_VM_MEMORY_MB at startup.   │
│  Auto-stops when idle. Wakes on connection.                │
└─────────────────────────────────────────────────────────────┘
```

**How connections work:** Your app connects to PgBouncer (port 6432), which multiplexes many client connections into a small pool of real Postgres connections. In transaction mode, a backend connection is only held for the duration of a transaction, then returned to the pool. This means 128 app connections might share just 5-16 real Postgres connections — critical for keeping memory low.

---

## File Structure

```
fly-pg-sandbox/
├── Dockerfile            # postgres:16-alpine + pgbouncer (269MB image)
├── docker-compose.yml    # local development (matches FLY_VM_MEMORY_MB)
├── entrypoint.sh         # auto-tunes PG + PgBouncer from memory, starts both
├── fly.toml              # Fly.io machine + service config
├── init.sql              # extensions + helper functions
├── Makefile              # all commands (make help)
├── .env.example          # env var reference
└── bin/
    ├── setup-fly.sh      # interactive/non-interactive Fly.io setup
    ├── create-db.sh      # create a database with all extensions
    ├── drop-db.sh        # drop a database (terminates connections first)
    └── tune.sh           # preview/apply PG settings for any memory size
```

---

## All Commands

### Local (Docker)

| Command | Description |
|---------|-------------|
| `make up` | Build image and start postgres + pgbouncer via docker compose |
| `make down` | Stop the container (data survives on the Docker volume) |
| `make clean` | Stop the container **and delete all data** (removes Docker volume) |
| `make test` | Verify postgres, pgbouncer, all extensions, and helper functions work |
| `make psql` | Connect via PgBouncer on port 6432 (same path as Fly.io) |
| `make psql-direct` | Connect directly to Postgres on port 54320 (bypasses PgBouncer) |
| `make psql-bouncer` | Connect to PgBouncer admin console (`SHOW POOLS`, `SHOW STATS`, etc.) |
| `make logs` | Tail docker compose container logs |
| `make status` | Show container status and count of active Postgres connections |
| `make shell` | Open a shell inside the container |
| `make create-db name=X` | Create a new database with all 13 extensions + helper functions |
| `make drop-db name=X` | Drop a database (terminates active connections first) |
| `make build` | Build the Docker image without starting it |
| `make tune` | Preview auto-tuned PG settings for all memory tiers (see [Tuning](#tuning)) |
| `make tune memory=512` | Preview settings for a specific memory size |
| `make tune memory=512 apply=1` | Apply settings (updates fly.toml + docker-compose.yml) |

### Fly.io (Remote)

All Fly.io commands check that `flyctl` is installed and exit with an install link if missing.

| Command | Description |
|---------|-------------|
| `make deploy` | Create a new Fly.io app — interactive prompts for all options |
| `make deploy name=X region=X ...` | Non-interactive deploy — pass flags, unset values get defaults |
| `make proxy` | Proxy Fly.io PgBouncer to localhost:6432 for local access |
| `make remote-test password=X` | Test Fly.io via proxy (requires `make proxy` running in another terminal) |
| `make remote-test-public password=X` | Test via public URL (requires `public` or `ipv6` access mode) |
| `make remote-test-public password=X host=IP` | Test via specific host/IP (useful if DNS hasn't propagated) |
| `make remote-logs` | Tail Fly.io application logs |
| `make ssh` | SSH into the Fly.io machine |
| `make grafana` | Open the Fly.io Grafana metrics dashboard in your browser |
| `make destroy` | Destroy the Fly.io app, volume, and IPs (asks you to type the app name) |
| `make destroy confirm=yes` | Destroy without confirmation (for scripts/CI) |

---

## Local Development

### Prerequisites

- Docker ([Get Docker](https://docs.docker.com/get-docker/))
- `psql` client (optional, for connecting)

### Start

```bash
make up      # build and start (1024MB memory limit)
make test    # verify postgres, pgbouncer, extensions, helper functions
make psql    # connect via pgbouncer (port 6432)
```

### Manage Databases

```bash
# Create (installs all 13 extensions + helper functions)
make create-db name=myapp
make create-db name=staging

# Drop (terminates active connections first)
make drop-db name=myapp

# Connect
psql "postgres://postgres:localdev@localhost:6432/myapp"
```

### PgBouncer Admin Console

Connect with `make psql-bouncer` to inspect connection pooling:

```sql
SHOW POOLS;     -- pool status: active, waiting, server connections per database
SHOW CLIENTS;   -- all connected client sessions
SHOW SERVERS;   -- backend Postgres connections in the pool
SHOW STATS;     -- query counts, bytes in/out, average query time
RELOAD;         -- reload pgbouncer config without restart
```

### Troubleshooting

**Container exits immediately:**
```bash
docker logs postgres-local
# Common: port conflict (another postgres on 6432), permission issues
```

**Can't connect:**
```bash
docker ps                                              # running?
docker exec postgres-local pg_isready -U postgres      # postgres ready?
docker exec postgres-local pgrep pgbouncer             # pgbouncer running?
```

**Reset everything:**
```bash
make clean && make up
```

---

## Deploy to Fly.io

### Prerequisites

- [flyctl](https://fly.io/docs/hands-on/install-flyctl/) installed (all `make` commands check this automatically)
- Fly account (`fly auth login`)

### One-Command Setup

```bash
make deploy
```

Interactively prompts for app name, region, password, database name, access mode, VM size, memory, and volume size. Shows all available options for each.

### Non-Interactive Deploy

Pass any flag to skip all prompts. Unset values get defaults.

```bash
# Minimal (free, internal only, connect via fly proxy)
make deploy name=my-db region=sjc access=proxy

# Public IPv6 only (free, requires IPv6 client)
make deploy name=my-db region=iad access=ipv6

# Public IPv4 + IPv6 (most compatible, +$2/mo)
make deploy name=my-db region=sjc access=public

# Bigger VM
make deploy name=my-db cpu=shared-cpu-2x memory=512 volume=5 access=public

# All flags
make deploy name=my-db region=sjc password=secret123 db=myapp access=public cpu=shared-cpu-1x memory=256 volume=1
```

| Flag | Default | Description |
|------|---------|-------------|
| `name` | `pg-sandbox-RANDOM` | Fly app name |
| `region` | `sjc` | Fly region (see below) |
| `password` | auto-generated | Postgres password (shown at end of setup) |
| `db` | `testdb` | Default database name |
| `access` | `proxy` | Access mode: `proxy`, `ipv6`, or `public` |
| `cpu` | `shared-cpu-1x` | VM size (see below) |
| `memory` | `256` | Memory in MB |
| `volume` | `1` | Volume size in GB |

### Regions

| Area | Regions |
|------|---------|
| US | `sjc` (San Jose), `lax` (Los Angeles), `ewr` (Secaucus NJ), `iad` (Ashburn VA), `ord` (Chicago), `dfw` (Dallas) |
| Canada | `yyz` (Toronto) |
| Europe | `ams` (Amsterdam), `cdg` (Paris), `fra` (Frankfurt), `lhr` (London), `arn` (Stockholm) |
| Asia | `nrt` (Tokyo), `sin` (Singapore), `bom` (Mumbai) |
| Other | `syd` (Sydney), `gru` (São Paulo), `jnb` (Johannesburg) |

### Access Modes

| Mode | Public? | Cost | How to Connect |
|------|---------|------|----------------|
| `proxy` | No | Free | `make proxy` then `psql ...@localhost:6432/db` |
| `ipv6` | IPv6 only | Free | `psql ...@app-name.fly.dev:5432/db` (requires IPv6 client) |
| `public` | IPv4 + IPv6 | +$2/mo | `psql ...@app-name.fly.dev:5432/db` (works everywhere) |

Choose `proxy` if your app also runs on Fly (use `.internal` address instead). Choose `public` if connecting from external platforms like Vercel, Railway, or your laptop without `fly proxy`.

### VM Sizes

| Size | Type | From |
|------|------|------|
| `shared-cpu-1x` | 1 shared (default) | $1.94/mo |
| `shared-cpu-2x` | 2 shared | $3.89/mo |
| `shared-cpu-4x` | 4 shared | $7.78/mo |
| `shared-cpu-6x` | 6 shared | $11.66/mo |
| `shared-cpu-8x` | 8 shared | $15.55/mo |
| `performance-1x` | 1 dedicated | $31/mo |
| `performance-2x` | 2 dedicated | $62/mo |
| `performance-4x` | 4 dedicated | $124/mo |
| `performance-6x` | 6 dedicated | $186/mo |
| `performance-8x` | 8 dedicated | $248/mo |
| `performance-10x` | 10 dedicated | $310/mo |
| `performance-12x` | 12 dedicated | $372/mo |
| `performance-14x` | 14 dedicated | $434/mo |
| `performance-16x` | 16 dedicated | $496/mo |

Prices are base (minimum RAM). Additional RAM is ~$5/GB/mo. Shared CPUs are fine for most use cases. Use `performance-*` for sustained query workloads. See [Fly.io pricing](https://fly.io/pricing) for full details.

### Memory

| Memory | PG Connections | PgBouncer Client Limit | Use Case |
|--------|---------------|----------------------|----------|
| 256 MB | ~16 | ~128 | Minimum, tiny side projects |
| 512 MB | ~32 | ~256 | Comfortable for most projects |
| 1024 MB | ~64 | ~512 | Multiple databases, heavier use |
| 2048 MB | ~128 | ~1000 | Heavy workloads |

PG connections are the real backend connections Postgres allocates (each uses ~3MB RAM). PgBouncer client limit is how many app connections PgBouncer will accept and multiplex into the smaller PG pool. Your app sees the client limit; Postgres only sees the pool.

> All settings are **auto-tuned** from `FLY_VM_MEMORY_MB` at container startup. Just pick a memory size.

### Volume Sizes

| Size | Use Case |
|------|----------|
| 1 GB | Small projects (default) |
| 5 GB | Multiple databases |
| 10 GB | Larger datasets |
| 20 GB | Heavy use |

Volumes can be extended later with `fly volumes extend <id> --size <gb>`, but cannot be shrunk.

### Auto-Stop / Auto-Start

The machine stays running. `fly.toml`:
```toml
auto_stop_machines = "off"
auto_start_machines = true
min_machines_running = 1
```

Stopping on idle looks like free money and is not, once anything serverless
connects. Vercel Functions, Lambda and friends keep pooled TCP connections alive
between invocations. When the machine stops, Fly tears out the proxy backhaul
and no FIN ever reaches the client, so the pool keeps handing out sockets that
are already dead — every query on one hangs until the client's own timeout
fires. A warm instance stays poisoned until it recycles, which turns a few
seconds of "cold start" into a multi-minute outage downstream, long after the
machine is back up. Keeping one machine running costs roughly $2/month and
removes the entire failure mode.

If nothing serverless connects and you want the savings back, set
`auto_stop_machines = "stop"` and `min_machines_running = 0`.

### Staying Reachable

Three settings exist specifically to stop dead connections from accumulating:

| Setting | Value | Why |
|---------|-------|-----|
| `tcp_keepidle` / `tcp_keepintvl` / `tcp_keepcnt` | 60 / 15 / 3 | Detects a peer that vanished without a FIN in ~2 minutes. The OS default waits ~2 hours, long enough for every client pool to fill with corpses. |
| `client_login_timeout` | 15s | A client that connects and never finishes logging in is wedged, not slow. The 60s default pins the slot for a minute per attempt, and a retrying serverless caller turns that into a pile of dead connections in seconds. |
| `client_idle_timeout` | 600s | Reaps pooled connections that have gone quiet, so a frozen or torn-down client cannot leave its half open forever. Clients reconnect transparently. |

### Health Checks

Fly's `fly.toml` checks only speak `tcp` and `http`. A TCP connect to 6432 goes
green the moment PgBouncer binds the port, which misses the failure that
actually matters: a pooler that accepts the socket and then never answers the
startup packet. That reads as healthy while every client hangs.

So `healthcheck.sh` probes with `pg_isready` — a real startup packet, no
password needed, since a server answering "authentication required" is a server
that is answering. `entrypoint.sh` runs it every 15 seconds and, after three
consecutive failures, kills PgBouncer so the container exits and Fly restarts
the machine. The TCP check in `fly.toml` stays on as a liveness floor.

This runs inside the machine, so it catches a wedged pooler. It cannot see a
broken Fly proxy path between an edge and this machine — nothing in the
container can.

### Connecting

**From another Fly app** (free, no proxy needed):
```
postgres://postgres:PASSWORD@app-name.internal:6432/testdb
```

**From anywhere** (requires `public` or `ipv6` access mode):
```
postgres://postgres:PASSWORD@app-name.fly.dev:5432/testdb
```

**Via proxy** (any access mode):
```bash
make proxy   # in one terminal
psql "postgres://postgres:PASSWORD@localhost:6432/testdb"
```

### Verify Deployment

```bash
# Via proxy
make proxy                                         # terminal 1
make remote-test password=YOUR_PASSWORD             # terminal 2

# Via public URL
make remote-test-public password=YOUR_PASSWORD
make remote-test-public password=YOUR_PASSWORD host=YOUR_IP  # if DNS hasn't propagated
```

### Teardown

```bash
make destroy              # interactive — asks you to type the app name to confirm
make destroy confirm=yes  # non-interactive — for scripts/CI, no confirmation
```

This destroys the Fly.io app, its volume (all data), allocated IPs, and secrets. There is no undo.

### Manual Setup

If you prefer step by step:

```bash
fly apps create my-app
fly volumes create pg_data --size 1 --region sjc --app my-app --yes
fly secrets set POSTGRES_PASSWORD=your_password --app my-app

# Optional: allocate public IPs
fly ips allocate-v6 --app my-app
fly ips allocate-v4 --app my-app --yes    # +$2/mo

# Edit fly.toml: set app name, region, vm size, and memory
fly deploy
```

> `make deploy` does all of this automatically, including updating `fly.toml` with your chosen VM size and memory.

### Useful Fly Commands

```bash
fly status                # machine status
fly machine list          # list machines
fly machine start ID      # manually start a stopped machine
fly machine restart ID    # restart
fly scale memory 512      # upgrade to 512MB
fly ips list              # show allocated IPs
fly ssh console           # SSH in
fly logs                  # tail logs
```

---

## Extensions

All 13 extensions are installed automatically on the default database and on any database created with `make create-db` or `SELECT create_db('name')`.

| Extension | Purpose | Example |
|-----------|---------|---------|
| `pg_stat_statements` | Query performance stats | `SELECT * FROM pg_stat_statements ORDER BY total_exec_time DESC;` |
| `pgcrypto` | Password hashing, encryption | `SELECT hash_password('secret');` |
| `pg_trgm` | Fuzzy text search | `SELECT * FROM users WHERE name % 'jon';` |
| `hstore` | Key-value column | `SELECT data->'color' FROM products;` |
| `citext` | Case-insensitive text | `CREATE TABLE t (email CITEXT UNIQUE);` |
| `btree_gin` | GIN indexes on scalars | Multi-column GIN indexes |
| `btree_gist` | GiST indexes on scalars | Exclusion constraints |
| `uuid-ossp` | UUID generation | `SELECT uuid_generate_v4();` |
| `unaccent` | Accent-insensitive search | `SELECT unaccent('cafe');` |
| `fuzzystrmatch` | Phonetic matching | `SELECT soundex('smith'), soundex('smyth');` |
| `pgstattuple` | Table bloat analysis | `SELECT * FROM pgstattuple('tablename');` |
| `dblink` | Cross-database queries | Used by `create_db()` helper |
| `plpgsql` | PL/pgSQL language | Procedural language (always installed) |

## Helper Functions

```sql
-- Hash a password (bcrypt)
SELECT hash_password('mysecret');

-- Verify a password against a hash
SELECT verify_password('mysecret', hash);

-- Auto-update updated_at on a table
CREATE TRIGGER set_updated_at BEFORE UPDATE ON your_table
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Create a new database with all extensions + helpers
SELECT create_db('myapp');

-- Drop a database (terminates connections first)
SELECT drop_db('myapp');
```

---

## Tuning

### How It Works

All PostgreSQL and PgBouncer settings are **auto-tuned** from `FLY_VM_MEMORY_MB` at container startup. The deploy script (`make deploy`) sets this env var to match your chosen memory. You never need to manually edit PostgreSQL or PgBouncer parameters.

`entrypoint.sh` computes the settings, generates `pgbouncer.ini`, and logs what was applied:

```
=== fly-pg-sandbox: 512MB ===
  PG:  shared_buffers=64MB effective_cache=128MB
  PG:  work_mem=2MB maint_mem=16MB max_conn=32
  PG:  parallel_gather=0 workers=2 autovacuum=1
  PGB: pool=10 reserve=5 max_db=21 max_client=256
```

Check with `make remote-logs` or `make logs` (local).

### Preview Settings

Use `make tune` to see what settings would be applied for any memory size — without changing anything:

```bash
make tune                   # compare all tiers side-by-side
make tune memory=512        # preview a specific memory size
make tune memory=768        # any custom value works
```

Example output (all tiers):

```
                                 256MB     512MB    1024MB    2048MB    4096MB
                              --------  --------  --------  --------  --------
  shared_buffers                  32MB      64MB     256MB     512MB    1024MB
  effective_cache_size            64MB     128MB     768MB    1536MB    3072MB
  work_mem                         1MB       2MB       4MB       8MB      16MB
  maintenance_work_mem             8MB      16MB      64MB     128MB     256MB
  max_connections                   16        32        64       128       256
  parallel_gather                    0         0         1         2         2
  ...
  pgb_pool                           5        10        21        42        50
  pgb_max_client                   128       256       512      1000      1000
```

### Apply Settings

To change the memory size and update all config files:

```bash
make tune memory=512 apply=1
```

This updates:
- **fly.toml** — `[vm] memory` and `[env] FLY_VM_MEMORY_MB`
- **docker-compose.yml** — `FLY_VM_MEMORY_MB` and `mem_limit`

Then deploy:

```bash
# Local
make down && make up

# Fly.io
fly deploy
```

### Tuning Formulas

| Parameter | <=512MB | >512MB | Min | Max |
|-----------|---------|--------|-----|-----|
| `shared_buffers` | RAM/8 | RAM/4 | 16MB | 1024MB |
| `effective_cache_size` | RAM/4 | RAM*3/4 | 32MB | 4096MB |
| `work_mem` | RAM/256 | RAM/256 | 1MB | 64MB |
| `maintenance_work_mem` | RAM/32 | RAM/16 | 8MB | 512MB |
| `max_connections` | RAM/16 | RAM/16 | 10 | 300 |
| Parallel query | off | on (1-2 workers) | — | — |
| Autovacuum workers | 1 | 1 (<=1GB) / 2 | — | — |

PgBouncer pool sizes scale proportionally with `max_connections`:

| PgBouncer Parameter | Formula |
|---------------------|---------|
| `default_pool_size` | max_connections / 3 |
| `reserve_pool_size` | pool / 2 (1-5) |
| `min_pool_size` | 0 (see below) |
| `max_db_connections` | max_connections * 2/3 |
| `max_client_conn` | max_connections * 8 (max 1000) |

> **Running many databases on one box?** Every PgBouncer limit above is applied
> *per (user, database) pair*, but `max_connections` is a single global budget for
> the server. Those two facts do not compose: with `default_pool_size = 21`, only
> four databases busy at the same time can ask for 84 backends against a global
> ceiling of 64, and the losers get `FATAL 53300 sorry, too many clients already`.
>
> `min_pool_size` is kept at 0 for the same reason — at any higher value, every
> database that has ever been connected to pins that many backends open forever,
> draining the global budget with no query running anywhere.
>
> If you host a database per project, size the machine for the number of databases
> you expect to be active *at once*, not for the number that exist.

### Reference: 256MB Memory Budget

| Component | Allocation |
|-----------|------------|
| OS + filesystem cache | ~80MB |
| shared_buffers | 32MB |
| PgBouncer | ~10MB |
| Per-connection overhead | ~50MB (16 conns x ~3MB) |
| work_mem (per sort) | 1MB |
| maintenance_work_mem | 8MB |
| pg_stat_statements | ~2MB |
| Headroom | ~60MB |

### Fixed Settings

These don't change with memory:

| Parameter | Value | Notes |
|-----------|-------|-------|
| `pool_mode` | transaction | Connections returned after each transaction |
| `auth_type` | scram-sha-256 | Secure password auth |
| `random_page_cost` | 1.1 | SSD-optimized |
| `effective_io_concurrency` | 200 | SSD-optimized |
| `log_min_duration_statement` | 1000ms | Log slow queries |
| `pg_stat_statements.max` | 1000 | Track top queries |
| `checkpoint_completion_target` | 0.9 | Spread checkpoint I/O |
| `checkpoint_timeout` | 10min | Checkpoint interval |

---

## Useful Queries

```sql
-- Top 10 slowest queries
SELECT calls, round(mean_exec_time::numeric, 2) AS mean_ms, query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;

-- Cache hit ratio (should be > 0.95)
SELECT sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0)
FROM pg_statio_user_tables;

-- Active connections
SELECT count(*) FROM pg_stat_activity WHERE state = 'active';

-- Reset query stats
SELECT pg_stat_statements_reset();
```

---

## Transaction Mode Caveats

PgBouncer runs in `transaction` mode. This means connections are shared between transactions, which is great for efficiency but breaks some Postgres features:

| Don't Use | Alternative |
|-----------|-------------|
| `SET variable = x` | `SET LOCAL variable = x` (inside transaction) |
| `LISTEN/NOTIFY` | Switch to `pool_mode = session` |
| Prepared statements | Disable in your ORM (e.g., `?pgbouncer=true` in Prisma) |
| Advisory locks | Wrap in explicit transaction |
| Temp tables | Use `ON COMMIT DROP` |

---

## Connecting From Your App

### Connection Strings

```bash
# From another Fly app (internal, recommended)
DATABASE_URL=postgres://postgres:PASSWORD@app-name.internal:6432/testdb

# Public (requires public or ipv6 access mode)
DATABASE_URL=postgres://postgres:PASSWORD@app-name.fly.dev:5432/testdb
```

### Framework Examples

**Node.js (pg)**
```javascript
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,  // pgbouncer handles real pooling
});
```

**Prisma**
```
# Add ?pgbouncer=true to disable prepared statements
DATABASE_URL=postgres://postgres:PASSWORD@app-name.fly.dev:5432/testdb?pgbouncer=true
```

**Python (psycopg2)**
```python
conn = psycopg2.connect(os.environ['DATABASE_URL'])
```

**Rails**
```yaml
production:
  url: <%= ENV['DATABASE_URL'] %>
  prepared_statements: false  # required for pgbouncer transaction mode
```

---

## Scaling Up

Choose larger VM, memory, and volume sizes during initial deploy (`make deploy cpu=... memory=... volume=...`). To scale an existing deployment:

| Symptom | Fix |
|---------|-----|
| OOM kills | `make tune memory=512 apply=1 && fly deploy` |
| Cache hit ratio < 90% | Increase RAM |
| Queries spilling to disk | Increase RAM (work_mem scales automatically) |
| PgBouncer pool full | Increase RAM (pool sizes scale automatically) |
| CPU throttled | `fly scale vm dedicated-cpu-1x` |
| Disk full | `fly volumes extend <id> --size <gb>` (cannot shrink) |

```bash
# 1. Preview what 512MB would look like
make tune memory=512

# 2. Apply (updates fly.toml + docker-compose.yml)
make tune memory=512 apply=1

# 3. Redeploy — settings auto-tune at startup
fly scale memory 512
fly deploy
```
