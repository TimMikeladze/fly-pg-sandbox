#!/bin/bash
set -e

DB_NAME="$1"
CONN="${2:-postgres://postgres:localdev@localhost:6432/testdb}"

if [ -z "$DB_NAME" ]; then
    echo "Usage: bin/create-db.sh <database-name> [connection-string]"
    echo ""
    echo "Creates a new database with all extensions and helper functions."
    echo ""
    echo "Examples:"
    echo "  bin/create-db.sh myapp"
    echo "  bin/create-db.sh myapp \"postgres://postgres:secret@localhost:6432/testdb\""
    exit 1
fi

echo "Creating database: $DB_NAME"
psql "$CONN" -v dbname="$DB_NAME" -c "SELECT create_db(:'dbname');" > /dev/null
echo "Done. Connect with:"
echo "  psql \"${CONN%/*}/$DB_NAME\""
