FROM almalinux:9 AS builder

RUN dnf install -y epel-release && \
    /usr/bin/crb enable && \
    dnf install -y \
    cmake gcc gcc-c++ make git python3 python3-pip \
    openssl-devel boost-devel glib2-devel \
    json-c-devel pugixml-devel \
    openldap-devel xrootd-client-devel libssh2-devel \
    libuuid-devel cryptopp-devel jsoncpp-devel \
    protobuf-devel cppzmq-devel doxygen \
    mysql-devel systemd-devel nlohmann-json-devel \
    curl-devel gtest-devel libxml2-devel gsoap-devel \
    libdirq-devel activemq-cpp-devel globus-gsi-credential-devel \
    soci-devel soci-mysql-devel gridsite-devel voms-devel \
    httpd-devel swig python3-devel \
    && dnf clean all

# Build davix
RUN git clone https://github.com/cern-fts/davix.git /tmp/davix && \
    mkdir /tmp/davix/build && cd /tmp/davix/build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DENABLE_THIRD_PARTY_COPY=ON && \
    make -j$(nproc) && make install && \
    rm -rf /tmp/davix

# Build GFAL2
RUN git clone https://github.com/cern-fts/gfal2.git /tmp/gfal2 && \
    mkdir /tmp/gfal2/build && cd /tmp/gfal2/build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DPLUGIN_DCAP=OFF -DPLUGIN_GRIDFTP=OFF \
    -DPLUGIN_SFTP=OFF -DPLUGIN_SRM=OFF -DSKIP_TESTS=TRUE && \
    make -j$(nproc) && make install && \
    rm -rf /tmp/gfal2

# Build FTS3
RUN git clone https://gitlab.cern.ch/fts/fts3.git /tmp/fts3 && \
    mkdir /tmp/fts3/build && cd /tmp/fts3/build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DALLBUILD=ON && \
    make -j$(nproc) && make install && \
    rm -rf /tmp/fts3

# Clone fts-rest-flask (kept for runtime Python path)
RUN git clone https://gitlab.cern.ch/fts/fts-rest-flask.git /tmp/fts-rest-flask && \
    cd /tmp/fts-rest-flask && \
    pip3 install setuptools_scm && \
    pip3 install -r requirements.in && \
    mkdir -p /usr/libexec/fts3rest && \
    cp /tmp/fts-rest-flask/src/fts3rest/fts3rest.wsgi /usr/libexec/fts3rest/fts3rest.wsgi

FROM almalinux:9 AS runtime

RUN dnf install -y epel-release && \
    /usr/bin/crb enable && \
    dnf install -y \
    python3 python3-pip \
    openssl glib2 openldap \
    xrootd-client libssh2 libuuid cryptopp jsoncpp \
    protobuf zeromq libxml2 gsoap \
    libdirq activemq-cpp globus-gsi-credential \
    soci-mysql gridsite voms \
    python3-mysqlclient mysql cronie \
    httpd mod_ssl python3-mod_wsgi \
    boost-thread boost-filesystem boost-system \
    boost-chrono boost-date-time boost-regex \
    boost-iostreams boost-atomic boost-timer \
    boost-program-options pugixml \
    && dnf clean all

# Python runtime dependencies
RUN pip3 install "sqlalchemy<2.0" pymysql

# Copy built binaries and libraries from builder
COPY --from=builder /usr/sbin/fts_* /usr/sbin/
COPY --from=builder /usr/sbin/fts_url_copy /usr/sbin/
COPY --from=builder /usr/lib64/libgfal_transfer* /usr/lib64/
COPY --from=builder /usr/lib64/libfts* /usr/lib64/
COPY --from=builder /usr/lib64/libdavix* /usr/lib64/
COPY --from=builder /usr/lib64/libgfal2* /usr/lib64/
COPY --from=builder /usr/lib64/gfal2-plugins/ /usr/lib64/gfal2-plugins/
COPY --from=builder /usr/share/fts/ /usr/share/fts/
COPY --from=builder /usr/share/fts-mysql/ /usr/share/fts-mysql/
COPY --from=builder /usr/libexec/fts3rest/ /usr/libexec/fts3rest/
COPY --from=builder /tmp/fts-rest-flask /tmp/fts-rest-flask
COPY --from=builder /usr/local/lib/python3.9/site-packages /usr/local/lib/python3.9/site-packages
COPY --from=builder /usr/local/lib64/python3.9/site-packages /usr/local/lib64/python3.9/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Generate self-signed certificates for testing
RUN mkdir -p /etc/grid-security/certificates && \
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/grid-security/hostkey.pem \
    -out /etc/grid-security/hostcert.pem \
    -subj "/CN=fts-test" && \
    chmod 600 /etc/grid-security/hostkey.pem && \
    chmod 644 /etc/grid-security/hostcert.pem && \
    cp /etc/grid-security/hostcert.pem /etc/grid-security/certificates/ && \
    openssl rehash /etc/grid-security/certificates/

# Create fts3 user and required directories
RUN useradd -r -m -u 9003 fts3 && \
    mkdir -p /var/log/fts3 /var/log/fts3rest /etc/fts3 /var/lib/fts3 && \
    chown -R fts3:fts3 /var/log/fts3 /var/log/fts3rest /var/lib/fts3 && \
    chmod +x /usr/share/fts/fts-database-upgrade.py

# Disable default httpd configs that conflict
RUN echo "" > /etc/httpd/conf.d/ssl.conf && \
    echo "" > /etc/httpd/conf.d/autoindex.conf && \
    echo "" > /etc/httpd/conf.d/userdir.conf && \
    echo "" > /etc/httpd/conf.d/welcome.conf && \
    echo "" > /etc/httpd/conf.d/zgridsite.conf && \
    echo "ServerName fts" >> /etc/httpd/conf/httpd.conf && \
    mkdir -p /etc/grid-security/certificates

# Pre-create log files with correct ownership
RUN touch /var/log/fts3/fts3server.log && \
    chown -R fts3:fts3 /var/log/fts3/fts3server.log && \
    touch /var/log/fts3rest/fts3rest.log && \
    chown -R fts3:fts3 /var/log/fts3rest

COPY config/fts3config /etc/fts3/fts3config
COPY config/fts3rest.conf /etc/httpd/conf.d/fts3rest.conf
COPY config/fts3restconfig /etc/fts3/fts3restconfig
COPY config/fts-activemq.conf /etc/fts3/fts-activemq.conf
COPY scripts/wait-for-it.sh /usr/local/bin/wait-for-it.sh
COPY scripts/docker-entrypoint.sh /docker-entrypoint.sh
COPY scripts/logshow /usr/local/bin/logshow
RUN chmod +x /usr/local/bin/wait-for-it.sh \
             /usr/local/bin/logshow \
             /docker-entrypoint.sh

EXPOSE 8446 8449
ENTRYPOINT ["/docker-entrypoint.sh"]