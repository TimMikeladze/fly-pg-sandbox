# pgvector is built from source in a throwaway stage so the runtime image carries only the
# compiled extension, not the toolchain. `with_llvm=no` skips the JIT bitcode (which would need
# the exact clang the base image was built with); the extension is unaffected.
FROM postgres:16-alpine AS pgvector
ARG PGVECTOR_VERSION=v0.8.0
RUN apk add --no-cache --virtual .build-deps git build-base \
    && git clone --branch "${PGVECTOR_VERSION}" --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make OPTFLAGS="" with_llvm=no \
    && make install with_llvm=no \
    && rm -rf /tmp/pgvector \
    && apk del .build-deps

FROM postgres:16-alpine

# Install pgbouncer (su-exec is included in postgres:alpine)
RUN apk add --no-cache pgbouncer

# pgvector: the shared object, the extension control/SQL files, and the headers.
COPY --from=pgvector /usr/local/lib/postgresql/vector.so /usr/local/lib/postgresql/vector.so
COPY --from=pgvector /usr/local/share/postgresql/extension/vector* /usr/local/share/postgresql/extension/
COPY --from=pgvector /usr/local/include/postgresql/server/extension/vector /usr/local/include/postgresql/server/extension/vector

# Create directories
RUN mkdir -p /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer \
    && chown -R postgres:postgres /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer

# Copy config files (pgbouncer.ini is generated at runtime by entrypoint.sh)
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
COPY init.sql /docker-entrypoint-initdb.d/init.sql

RUN chmod +x /entrypoint.sh /healthcheck.sh

EXPOSE 5432 6432

ENTRYPOINT ["/entrypoint.sh"]
