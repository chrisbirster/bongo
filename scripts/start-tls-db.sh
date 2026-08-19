#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tls_dir="$root/.bongo-tls"
mkdir -p "$tls_dir"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$tls_dir/server-key.pem" \
  -out "$tls_dir/server-cert.pem" \
  -days 2 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

cat "$tls_dir/server-key.pem" "$tls_dir/server-cert.pem" > "$tls_dir/mongodb.pem"
chmod 600 "$tls_dir/mongodb.pem"

docker rm -f mongodb-tls >/dev/null 2>&1 || true

docker run -d \
  --name mongodb-tls \
  -p 27018:27017 \
  -v "$tls_dir:/tls:ro" \
  -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD=secretpassword \
  mongo:latest \
  --tlsMode requireTLS \
  --tlsCertificateKeyFile /tls/mongodb.pem \
  --tlsCAFile /tls/server-cert.pem \
  --bind_ip_all

echo "TLS MongoDB fixture listening on localhost:27018"
echo "Run: zig build tls-integration-test"
