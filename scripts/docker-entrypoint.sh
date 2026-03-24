#!/bin/bash

set -e -o pipefail

# wait for MySQL readiness
/usr/local/bin/wait-for-it.sh -h ftsdb -p 3306 -t 3600

# initialise / upgrade the database (ignore non-fatal upgrade errors)
/usr/share/fts/fts-database-upgrade.py -y || true

# Hash CA certificates so Apache's SSLCACertificatePath can find them
openssl rehash /etc/grid-security/certificates/

# Disable XRootD server hostname verification for GSI auth.
# Certs use CN=xrd rather than the full Docker container hostname,
# so fts_url_copy would otherwise reject the XRootD server certificate.
export XrdSecGSISRVNAMES="*"

# startup the FTS services
/usr/sbin/fts_server               # main FTS server daemonizes
/usr/sbin/fts_activemq             # daemon to send messages to activemq
/usr/sbin/fts_token                # daemon to manage token
/usr/sbin/fts_qos                  # daemon to handle staging requests
exec /usr/sbin/httpd -DFOREGROUND  # FTS REST frontend & FTSMON