# Certificate Setup

Certificates are **not** baked into the image. They must be provided at runtime via volume mounts (docker-compose) or Kubernetes Secrets.

The CA certificate must be mounted at the correct OpenSSL hash path. The `rucio_ca.pem` from `k8s-tutorial/secrets/` has hash `5fca1cb1`, so it must be mounted as `5fca1cb1.0`.

## Generating certificates for local testing

If you need to generate new leaf certificates from the Rucio CA (requires the CA private key):

```bash
# FTS host cert — must include Key Usage for XRootD GSI TPC proxy delegation
cat > /tmp/fts-ext.cnf << 'EOF'
[ v3_req ]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl req -nodes -newkey rsa:2048 \
  -keyout certs/hostkey.pem \
  -out    certs/hostcert.csr \
  -subj "/CN=fts"
openssl x509 -req -days 365 \
  -in certs/hostcert.csr \
  -CA certs/rucio_ca.pem -CAkey certs/rucio_ca.key.pem -CAcreateserial \
  -extfile /tmp/fts-ext.cnf -extensions v3_req \
  -out certs/hostcert.pem
chmod 600 certs/hostkey.pem

# XRootD cert
openssl req -nodes -newkey rsa:2048 \
  -keyout certs/xrdkey.pem \
  -out    certs/xrdcert.csr \
  -subj "/CN=xrd"
openssl x509 -req -days 365 \
  -in certs/xrdcert.csr \
  -CA certs/rucio_ca.pem -CAkey certs/rucio_ca.key.pem -CAcreateserial \
  -out certs/xrdcert.pem
chmod 600 certs/xrdkey.pem

# WebDAV certs — CN must match each container hostname
for host in webdav1 webdav2; do
  openssl req -nodes -newkey rsa:2048 \
    -keyout certs/${host}key.pem \
    -out    certs/${host}cert.csr \
    -subj "/CN=${host}"
  openssl x509 -req -days 365 \
    -in certs/${host}cert.csr \
    -CA certs/rucio_ca.pem -CAkey certs/rucio_ca.key.pem -CAcreateserial \
    -out certs/${host}cert.pem
  chmod 600 certs/${host}key.pem
done

rm -f certs/*.csr certs/*.srl /tmp/fts-ext.cnf
```

> **NOTE:** The FTS host certificate **must** include `Key Usage = digitalSignature, keyEncipherment`. Without this, XRootD's GSI implementation cannot create a proxy certificate for TPC authentication, causing transfers to fail with `no delegated credentials for tpc`.

> **NOTE:** XRootD certificates use `CN=xrd` (not a hostname). The docker-compose stack sets `XrdSecGSISRVNAMES=*` to bypass hostname verification, which is required because the cert CN does not match the Docker container hostname.

> **NOTE:** Each WebDAV certificate must use a CN matching its container hostname (`CN=webdav1`, `CN=webdav2`). Connections from inside the Docker network use these hostnames for TLS SNI validation.

## Kubernetes

Certificates are stored as Kubernetes Secrets and volume-mounted into the pod. See `k8s-tutorial/manifests/fts.yaml` for the full manifest.

```bash
kubectl create secret tls hostcert-fts \
  --cert=certs/hostcert.pem \
  --key=certs/hostkey.pem \
  -n rucio-tutorial

kubectl create secret generic ca-cert \
  --from-file=tls.cert=certs/rucio_ca.pem \
  -n rucio-tutorial
```