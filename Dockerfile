FROM postgres:16-alpine

# Install pgbouncer (su-exec is included in postgres:alpine)
RUN apk add --no-cache pgbouncer

# Create directories
RUN mkdir -p /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer \
    && chown -R postgres:postgres /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer

# Copy config files (pgbouncer.ini is generated at runtime by entrypoint.sh)
COPY entrypoint.sh /entrypoint.sh
COPY init.sql /docker-entrypoint-initdb.d/init.sql

RUN chmod +x /entrypoint.sh

EXPOSE 5432 6432

ENTRYPOINT ["/entrypoint.sh"]
