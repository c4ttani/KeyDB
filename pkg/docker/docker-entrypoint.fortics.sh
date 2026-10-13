#!/bin/sh
# Same behaviour as the entrypoint generated in pkg/docker/Dockerfile.
set -e
# first arg is '-f' or '--some-option', or first arg is 'something.conf'
if [ "${1#-}" != "$1" ] || [ "${1%.conf}" != "$1" ]; then
        set -- keydb-server "$@"
fi
# if KEYDB_PASSWORD is set, add it to the arguments
if [ "$1" = "keydb-server" ] && [ -n "$KEYDB_PASSWORD" ]; then
        set -- "$@" --requirepass "${KEYDB_PASSWORD}"
fi
# allow the container to be started with `--user`
if [ "$1" = "keydb-server" ] && [ "$(id -u)" = "0" ]; then
        find . \! -user keydb -exec chown keydb '{}' +
        exec gosu keydb "$0" "$@"
fi
exec "$@"
