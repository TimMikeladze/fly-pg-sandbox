#!/bin/bash
set -e

DB_NAME="$1"
CONN="${2:-postgres://postgres:localdev@localhost:6432/testdb}"

if [ -z "$DB_NAME" ]; then
    echo "Usage: bin/drop-db.sh <database-name> [connection-string]"
    echo ""
    echo "Terminates active connections and drops the database."
    echo ""
    echo "Examples:"
    echo "  bin/drop-db.sh myapp"
    echo "  bin/drop-db.sh myapp \"postgres://postgres:secret@localhost:6432/testdb\""
    exit 1
fi

echo "Dropping database: $DB_NAME"
psql "$CONN" -v dbname="$DB_NAME" -c "SELECT drop_db(:'dbname');" > /dev/null
echo "Done."
