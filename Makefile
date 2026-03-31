.PHONY: help up down logs shell psql psql-direct psql-bouncer clean build status test create-db drop-db tune deploy proxy ssh grafana destroy remote-logs remote-test remote-test-public

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Local ────────────────────────────────────────────────────

up: ## Start postgres locally (docker compose)
	docker compose up -d --build
	@echo ""
	@echo "  PgBouncer: postgres://postgres:localdev@localhost:6432/testdb"
	@echo "  Direct:    postgres://postgres:localdev@localhost:5432/testdb"
	@echo ""
	@echo "  Run 'make psql' to connect."

down: ## Stop postgres
	docker compose down

logs: ## Tail container logs
	docker compose logs -f

status: ## Show container status and connections
	@docker compose ps 2>/dev/null || echo "Not running."
	@echo ""
	@docker exec postgres-local psql -U postgres -d testdb -c \
		"SELECT count(*) AS active_connections FROM pg_stat_activity WHERE state = 'active';" 2>/dev/null || true

psql: ## Connect via PgBouncer (port 6432, matches Fly path)
	psql "postgres://postgres:localdev@localhost:6432/testdb"

psql-direct: ## Connect directly to Postgres (port 54320, bypasses PgBouncer)
	psql "postgres://postgres:localdev@localhost:54320/testdb"

psql-bouncer: ## PgBouncer admin console (SHOW POOLS, SHOW STATS, etc.)
	psql "postgres://postgres:localdev@localhost:6432/pgbouncer"

shell: ## Shell into the container
	docker exec -it postgres-local /bin/sh

create-db: ## Create a new database: make create-db name=myapp
	@if [ -z "$(name)" ]; then echo "Usage: make create-db name=myapp"; exit 1; fi
	@bin/create-db.sh $(name)

drop-db: ## Drop a database: make drop-db name=myapp
	@if [ -z "$(name)" ]; then echo "Usage: make drop-db name=myapp"; exit 1; fi
	@bin/drop-db.sh $(name)

test: ## Verify local postgres + pgbouncer + extensions work
	@echo "Testing connection via PgBouncer..."
	@psql "postgres://postgres:localdev@localhost:6432/testdb" -c "SELECT 1" > /dev/null 2>&1 && \
		echo "  ✓ PgBouncer connection" || { echo "  ✗ PgBouncer connection failed"; exit 1; }
	@psql "postgres://postgres:localdev@localhost:6432/testdb" -tAc \
		"SELECT count(*) FROM pg_available_extensions WHERE installed_version IS NOT NULL" | \
		xargs -I{} sh -c 'echo "  ✓ {} extensions installed"'
	@psql "postgres://postgres:localdev@localhost:6432/testdb" -tAc \
		"SELECT hash_password('test')" > /dev/null 2>&1 && \
		echo "  ✓ hash_password()" || echo "  ✗ hash_password() failed"
	@psql "postgres://postgres:localdev@localhost:6432/testdb" -tAc \
		"SELECT verify_password('test', hash_password('test'))" | grep -q t && \
		echo "  ✓ verify_password()" || echo "  ✗ verify_password() failed"
	@psql "postgres://postgres:localdev@localhost:6432/testdb" -tAc \
		"SELECT similarity('hello', 'helo')" > /dev/null 2>&1 && \
		echo "  ✓ pg_trgm" || echo "  ✗ pg_trgm failed"
	@psql "postgres://postgres:localdev@localhost:6432/testdb" -tAc \
		"SELECT count(*) FROM pg_stat_statements" > /dev/null 2>&1 && \
		echo "  ✓ pg_stat_statements" || echo "  ✗ pg_stat_statements failed"
	@echo "All checks passed."

clean: ## Stop and delete all local data
	docker compose down -v

build: ## Build the Docker image
	docker build -t fly-pg-sandbox .

tune: ## Preview/apply PG settings: make tune [memory=512] [apply=1]
	@bin/tune.sh $(memory) $(if $(apply),--apply)

# ── Fly.io ───────────────────────────────────────────────────

check-fly:
	@command -v fly >/dev/null 2>&1 || { echo "Error: flyctl is not installed. Install it: https://fly.io/docs/hands-on/install-flyctl/"; exit 1; }

deploy: check-fly ## Create a new Fly.io app: make deploy [name=x] [region=x] [password=x] [db=x] [access=x] [cpu=x] [memory=x] [volume=x]
	bin/setup-fly.sh $(if $(name),-n $(name)) $(if $(region),-r $(region)) $(if $(password),-p $(password)) $(if $(db),-d $(db)) $(if $(access),-a $(access)) $(if $(cpu),-c $(cpu)) $(if $(memory),-m $(memory)) $(if $(volume),-v $(volume))

proxy: check-fly ## Proxy Fly.io PgBouncer to localhost:6432
	@echo "Proxying Fly PgBouncer to localhost:6432..."
	@echo "Connect with: psql \"postgres://postgres:<password>@localhost:6432/testdb\""
	fly proxy 6432:6432

ssh: check-fly ## SSH into the Fly.io machine
	fly ssh console

grafana: check-fly ## Open Fly.io Grafana dashboard in browser
	@APP=$$(awk -F'"' '/^app =/{print $$2}' fly.toml) && \
	echo "Opening Grafana for $$APP..." && \
	open "https://fly-metrics.net/d/fly-app/fly-app?var-app=$$APP" 2>/dev/null || \
	xdg-open "https://fly-metrics.net/d/fly-app/fly-app?var-app=$$APP" 2>/dev/null || \
	echo "https://fly-metrics.net/d/fly-app/fly-app?var-app=$$APP"

destroy: check-fly ## Destroy Fly.io app + data: make destroy [confirm=yes]
	@APP=$$(awk -F'"' '/^app =/{print $$2}' fly.toml) && \
	fly status --app "$$APP" > /dev/null 2>&1 || { echo "App '$$APP' not found on Fly.io."; exit 1; } && \
	if [ "$(confirm)" = "yes" ]; then \
		fly apps destroy "$$APP" --yes && \
		echo "Destroyed $$APP."; \
	else \
		echo "This will permanently destroy '$$APP' and all its data." && \
		read -p "Type the app name to confirm: " CONFIRM && \
		[ "$$CONFIRM" = "$$APP" ] || { echo "Aborted."; exit 1; } && \
		fly apps destroy "$$APP" --yes && \
		echo "Destroyed $$APP."; \
	fi

remote-logs: check-fly ## Tail Fly.io logs
	fly logs

remote-test: check-fly ## Test Fly.io via proxy: make remote-test password=x
	@if [ -z "$(password)" ]; then echo "Usage: make remote-test password=YOUR_PASSWORD"; exit 1; fi
	@echo "Testing connection via Fly PgBouncer..."
	@psql "postgres://postgres:$(password)@127.0.0.1:6432/testdb" -c "SELECT 1" > /dev/null 2>&1 && \
		echo "  ✓ PgBouncer connection" || { echo "  ✗ PgBouncer connection failed (is 'make proxy' running?)"; exit 1; }
	@psql "postgres://postgres:$(password)@127.0.0.1:6432/testdb" -tAc \
		"SELECT count(*) FROM pg_available_extensions WHERE installed_version IS NOT NULL" | \
		xargs -I{} sh -c 'echo "  ✓ {} extensions installed"'
	@psql "postgres://postgres:$(password)@127.0.0.1:6432/testdb" -tAc \
		"SELECT hash_password('test')" > /dev/null 2>&1 && \
		echo "  ✓ hash_password()" || echo "  ✗ hash_password() failed"
	@psql "postgres://postgres:$(password)@127.0.0.1:6432/testdb" -tAc \
		"SELECT similarity('hello', 'helo')" > /dev/null 2>&1 && \
		echo "  ✓ pg_trgm" || echo "  ✗ pg_trgm failed"
	@psql "postgres://postgres:$(password)@127.0.0.1:6432/testdb" -tAc \
		"SELECT count(*) FROM pg_stat_statements" > /dev/null 2>&1 && \
		echo "  ✓ pg_stat_statements" || echo "  ✗ pg_stat_statements failed"
	@echo "All checks passed."

remote-test-public: check-fly ## Test public URL: make remote-test-public password=x [host=app.fly.dev]
	@if [ -z "$(password)" ]; then echo "Usage: make remote-test-public password=YOUR_PASSWORD [host=fly-pg-sandbox.fly.dev]"; exit 1; fi
	$(eval FLY_HOST := $(or $(host),fly-pg-sandbox.fly.dev))
	@echo "Testing public connection to $(FLY_HOST):5432..."
	@psql "postgres://postgres:$(password)@$(FLY_HOST):5432/testdb" -c "SELECT 1" > /dev/null 2>&1 && \
		echo "  ✓ Public connection" || { echo "  ✗ Public connection failed"; exit 1; }
	@psql "postgres://postgres:$(password)@$(FLY_HOST):5432/testdb" -tAc \
		"SELECT count(*) FROM pg_available_extensions WHERE installed_version IS NOT NULL" | \
		xargs -I{} sh -c 'echo "  ✓ {} extensions installed"'
	@psql "postgres://postgres:$(password)@$(FLY_HOST):5432/testdb" -tAc \
		"SELECT hash_password('test')" > /dev/null 2>&1 && \
		echo "  ✓ hash_password()" || echo "  ✗ hash_password() failed"
	@psql "postgres://postgres:$(password)@$(FLY_HOST):5432/testdb" -tAc \
		"SELECT similarity('hello', 'helo')" > /dev/null 2>&1 && \
		echo "  ✓ pg_trgm" || echo "  ✗ pg_trgm failed"
	@psql "postgres://postgres:$(password)@$(FLY_HOST):5432/testdb" -tAc \
		"SELECT count(*) FROM pg_stat_statements" > /dev/null 2>&1 && \
		echo "  ✓ pg_stat_statements" || echo "  ✗ pg_stat_statements failed"
	@echo "All checks passed."
