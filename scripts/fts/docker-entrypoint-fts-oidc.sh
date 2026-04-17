#!/bin/bash
set -o pipefail
# wait for the correct DB — ftsdb-oidc, not ftsdb
/usr/local/bin/wait-for-it.sh -h ftsdb-oidc -p 3306 -t 3600

# initialise / upgrade the database — ignore ALL errors (duplicate keys etc.)
/usr/share/fts/fts-database-upgrade.py -y 2>&1 || echo "DB upgrade finished (errors ignored)"

# Hash CA certificates
openssl rehash /etc/grid-security/certificates/ 2>/dev/null || true

# Start FTS daemons
/usr/sbin/fts_server  || echo "fts_server exited"
/usr/sbin/fts_token   || echo "fts_token exited"

# Start Apache in foreground
exec /usr/sbin/httpd -DFOREGROUND
