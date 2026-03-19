#!/bin/bash

/usr/local/bin/wait-for-it.sh -h ftsdb -p 3306 -t 3600

/usr/share/fts/fts-database-upgrade.py -y; echo "DB upgrade done (exit: $?)"

/usr/sbin/fts_server || echo "fts_server exited"
/usr/sbin/fts_activemq || echo "fts_activemq exited"
/usr/sbin/fts_token || echo "fts_token exited"
/usr/sbin/fts_qos || echo "fts_qos exited"

# Start httpd in background, fall back to tail if it fails
/usr/sbin/httpd -DFOREGROUND &
HTTPD_PID=$!

# Keep container alive via log tail
exec tail -f /var/log/fts3/fts3server.log