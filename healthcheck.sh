#!/bin/sh
# Fly health check for the pooler.
#
# The old check was a bare TCP connect to 6432, which reports healthy as soon as
# PgBouncer binds the port. That hides the failure that actually happens: the
# pooler accepts a connection, registers the database, and then never answers
# the startup packet, leaving clients to hang until their own timeout fires.
#
# pg_isready sends a real startup packet and waits for the server's reply. It
# does not authenticate, so no password is needed here — a server that answers
# "authentication required" is a server that is answering.
#
# This runs inside the machine, so it proves PostgreSQL and PgBouncer are
# talking. It cannot see the Fly proxy path between an edge and this machine.
set -e

PG_USER="${POSTGRES_USER:-postgres}"

# PostgreSQL itself, over its unix socket.
pg_isready -q -h /var/run/postgresql -U "$PG_USER"

# PgBouncer, over TCP, the way real clients arrive.
pg_isready -q -h 127.0.0.1 -p 6432 -U "$PG_USER"
