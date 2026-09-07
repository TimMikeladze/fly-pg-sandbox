-- =============================================================================
-- EXTENSIONS (for the default database)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS vector;

-- =============================================================================
-- DATABASE MANAGEMENT HELPERS
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS dblink;

-- Create a new database and install all extensions into it
CREATE OR REPLACE FUNCTION create_db(dbname TEXT)
RETURNS VOID AS $$
BEGIN
    -- Create the database
    PERFORM dblink_exec(
        'dbname=' || current_database(),
        'CREATE DATABASE ' || quote_ident(dbname)
    );

    -- Install extensions in the new database
    PERFORM dblink_exec(
        'dbname=' || quote_ident(dbname),
        'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
         CREATE EXTENSION IF NOT EXISTS pgcrypto;
         CREATE EXTENSION IF NOT EXISTS pg_trgm;
         CREATE EXTENSION IF NOT EXISTS hstore;
         CREATE EXTENSION IF NOT EXISTS citext;
         CREATE EXTENSION IF NOT EXISTS btree_gin;
         CREATE EXTENSION IF NOT EXISTS btree_gist;
         CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
         CREATE EXTENSION IF NOT EXISTS unaccent;
         CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
         CREATE EXTENSION IF NOT EXISTS pgstattuple;
         CREATE EXTENSION IF NOT EXISTS vector;'
    );

    -- Install helper functions in the new database
    PERFORM dblink_exec(
        'dbname=' || quote_ident(dbname),
        $fn$
        CREATE OR REPLACE FUNCTION hash_password(password TEXT)
        RETURNS TEXT AS $i$
            SELECT crypt(password, gen_salt('bf', 8));
        $i$ LANGUAGE SQL VOLATILE;

        CREATE OR REPLACE FUNCTION verify_password(password TEXT, hash TEXT)
        RETURNS BOOLEAN AS $i$
            SELECT crypt(password, hash) = hash;
        $i$ LANGUAGE SQL IMMUTABLE;

        CREATE OR REPLACE FUNCTION set_updated_at()
        RETURNS TRIGGER AS $i$
        BEGIN
            NEW.updated_at = NOW();
            RETURN NEW;
        END;
        $i$ LANGUAGE plpgsql;
        $fn$
    );
END;
$$ LANGUAGE plpgsql;

-- Drop a database (terminates active connections first)
CREATE OR REPLACE FUNCTION drop_db(dbname TEXT)
RETURNS VOID AS $$
BEGIN
    -- Terminate connections
    PERFORM pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = dbname AND pid <> pg_backend_pid();

    -- Drop the database
    PERFORM dblink_exec(
        'dbname=' || current_database(),
        'DROP DATABASE IF EXISTS ' || quote_ident(dbname)
    );
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Hash a password using bcrypt
CREATE OR REPLACE FUNCTION hash_password(password TEXT)
RETURNS TEXT AS $$
    SELECT crypt(password, gen_salt('bf', 8));
$$ LANGUAGE SQL VOLATILE;

-- Verify a password against a hash
CREATE OR REPLACE FUNCTION verify_password(password TEXT, hash TEXT)
RETURNS BOOLEAN AS $$
    SELECT crypt(password, hash) = hash;
$$ LANGUAGE SQL IMMUTABLE;

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Usage:
-- CREATE TRIGGER set_updated_at BEFORE UPDATE ON your_table
--     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
