FROM almalinux:9

# Base build deps
RUN dnf install -y epel-release && \
    /usr/bin/crb enable && \
    dnf install -y \
    cmake gcc gcc-c++ make git python3 python3-pip \
    openssl-devel boost-devel glib2-devel \
    json-c-devel pugixml-devel supervisor cronie \
    openldap-devel xrootd-client-devel libssh2-devel \
    libuuid-devel cryptopp-devel jsoncpp-devel \
    protobuf-devel cppzmq-devel doxygen \
    mysql-devel systemd-devel nlohmann-json-devel \
    curl-devel gtest-devel libxml2-devel gsoap-devel \
    libdirq-devel activemq-cpp-devel globus-gsi-credential-devel \
    soci-devel soci-mysql-devel gridsite-devel voms-devel \
    python3-mysqlclient mysql gridsite httpd-devel \
    httpd mod_ssl python3-mod_wsgi swig python3-devel \
    && dnf clean all

# Python dependencies
RUN pip3 install "sqlalchemy<2.0" pymysql

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

# Install fts-rest-flask (REST frontend)
# Keep source until wsgi file is copied, then clean up
RUN git clone https://gitlab.cern.ch/fts/fts-rest-flask.git /tmp/fts-rest-flask && \
    cd /tmp/fts-rest-flask && \
    pip3 install setuptools_scm && \
    pip3 install -r requirements.in && \
    mkdir -p /usr/libexec/fts3rest && \
    cp /tmp/fts-rest-flask/src/fts3rest/fts3rest.wsgi /usr/libexec/fts3rest/fts3rest.wsgi

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