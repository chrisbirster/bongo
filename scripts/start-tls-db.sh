#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tls_dir="$root/.bongo-tls"
MONGO_IMAGE="${MONGO_IMAGE:-mongo:8.0}"
mkdir -p "$tls_dir"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$tls_dir/server-key.pem" \
  -out "$tls_dir/server-cert.pem" \
  -days 2 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

cat "$tls_dir/server-key.pem" "$tls_dir/server-cert.pem" > "$tls_dir/mongodb.pem"
# This is a disposable local/CI fixture. The bind-mounted file must be readable
# by the non-root `mongod` user inside the official container.
chmod 644 "$tls_dir/mongodb.pem" "$tls_dir/server-cert.pem"

docker rm -f mongodb-tls >/dev/null 2>&1 || true

docker run -d \
  --name mongodb-tls \
  -p 27018:27017 \
  -v "$tls_dir:/tls:ro" \
  -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD=secretpassword \
  "$MONGO_IMAGE" \
  --tlsMode requireTLS \
  --tlsCertificateKeyFile /tls/mongodb.pem \
  --tlsCAFile /tls/server-cert.pem \
  --tlsAllowConnectionsWithoutCertificates \
  --bind_ip_all

# Current MongoDB requires a CA source whenever TLS is enabled. The fixture
# supplies the generated certificate as that trust root but explicitly allows
# clients without certificates. This validates the Deez requirement: verified
# server TLS followed by SCRAM, not MONGODB-X509/mutual TLS.
for attempt in $(seq 1 60); do
  if docker exec mongodb-tls mongosh \
      --quiet \
      --tls \
      --tlsAllowInvalidCertificates \
      --username admin \
      --password secretpassword \
      --authenticationDatabase admin \
      --eval 'quit(db.runCommand({ping: 1}).ok === 1 ? 0 : 1)' \
      >/dev/null 2>&1; then
    echo "TLS MongoDB fixture ready on localhost:27018"
    echo "Run: zig build tls-integration-test"
    exit 0
  fi
  sleep 1
done

echo "TLS MongoDB fixture failed to become ready" >&2
docker logs mongodb-tls >&2 || true
exit 1
