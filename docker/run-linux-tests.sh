#!/usr/bin/env bash
set -euo pipefail

ROOT=/workspace
MONGO_USER="${MONGO_INITDB_ROOT_USERNAME:-admin}"
MONGO_PASSWORD="${MONGO_INITDB_ROOT_PASSWORD:-secretpassword}"
MONGO_PID=""

cd "$ROOT"

stop_mongo() {
  if [[ -n "${MONGO_PID:-}" ]] && kill -0 "$MONGO_PID" >/dev/null 2>&1; then
    kill "$MONGO_PID" >/dev/null 2>&1 || true
    wait "$MONGO_PID" >/dev/null 2>&1 || true
  fi
  MONGO_PID=""
}

cleanup() {
  stop_mongo
}
trap cleanup EXIT INT TERM

reset_dbpath() {
  local path="$1"
  mkdir -p "$path"
  find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

wait_plain_auth() {
  for _ in $(seq 1 90); do
    if mongosh --quiet \
      --host localhost \
      --port 27017 \
      --username "$MONGO_USER" \
      --password "$MONGO_PASSWORD" \
      --authenticationDatabase admin \
      --eval 'quit(db.runCommand({ping:1}).ok === 1 ? 0 : 1)' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Plain MongoDB fixture did not become ready" >&2
  return 1
}

wait_tls_auth() {
  for _ in $(seq 1 90); do
    if mongosh --quiet \
      --host localhost \
      --port 27018 \
      --tls \
      --tlsCAFile "$ROOT/.bongo-tls/server-cert.pem" \
      --username "$MONGO_USER" \
      --password "$MONGO_PASSWORD" \
      --authenticationDatabase admin \
      --eval 'quit(db.runCommand({ping:1}).ok === 1 ? 0 : 1)' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "TLS MongoDB fixture did not become ready" >&2
  return 1
}

wait_replica() {
  for _ in $(seq 1 90); do
    if mongosh --quiet --host localhost --port 27019 \
      --eval 'quit(db.runCommand({ping:1}).ok === 1 ? 0 : 1)' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Replica-set MongoDB fixture did not start" >&2
  return 1
}

wait_primary() {
  for _ in $(seq 1 90); do
    if mongosh --quiet --host localhost --port 27019 \
      --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Replica-set MongoDB fixture did not elect a primary" >&2
  return 1
}

echo "==> Environment"
echo "Linux: $(uname -a)"
echo "Zig:   $(zig version)"
echo "Mongo: $(mongod --version | head -n 1)"

echo "==> Unit tests"
zig build test

echo "==> Plain MongoDB integration fixture"
reset_dbpath /data/db
export MONGO_INITDB_ROOT_USERNAME="$MONGO_USER"
export MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASSWORD"
/usr/local/bin/docker-entrypoint.sh mongod \
  --bind_ip 127.0.0.1 \
  --port 27017 &
MONGO_PID=$!
wait_plain_auth

echo "==> Standard integration tests"
zig build integration-test
stop_mongo

echo "==> TLS fixture"
rm -rf "$ROOT/.bongo-tls"
mkdir -p "$ROOT/.bongo-tls"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$ROOT/.bongo-tls/server-key.pem" \
  -out "$ROOT/.bongo-tls/server-cert.pem" \
  -days 2 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  >/dev/null 2>&1
cat "$ROOT/.bongo-tls/server-key.pem" "$ROOT/.bongo-tls/server-cert.pem" \
  > "$ROOT/.bongo-tls/mongodb.pem"
# docker-entrypoint.sh drops privileges before starting mongod. Keep the
# private-key bundle restricted, but make the mongodb user its owner so mongod
# can read it after the privilege drop.
chown mongodb:mongodb "$ROOT/.bongo-tls/mongodb.pem" "$ROOT/.bongo-tls/server-cert.pem"
chmod 600 "$ROOT/.bongo-tls/mongodb.pem"
chmod 644 "$ROOT/.bongo-tls/server-cert.pem"

/usr/local/bin/docker-entrypoint.sh mongod \
  --bind_ip 127.0.0.1 \
  --port 27018 \
  --tlsMode requireTLS \
  --tlsCertificateKeyFile "$ROOT/.bongo-tls/mongodb.pem" \
  --tlsCAFile "$ROOT/.bongo-tls/server-cert.pem" \
  --tlsAllowConnectionsWithoutCertificates &
MONGO_PID=$!
wait_tls_auth

echo "==> Verified TLS + SCRAM integration test"
zig build tls-integration-test
stop_mongo

echo "==> Replica-set fixture"
reset_dbpath /data/rs
mongod \
  --dbpath /data/rs \
  --bind_ip 127.0.0.1 \
  --port 27019 \
  --replSet rs0 \
  --logpath /tmp/mongodb-rs.log &
MONGO_PID=$!
wait_replica
mongosh --quiet --host localhost --port 27019 --eval \
  'rs.initiate({_id:"rs0", members:[{_id:0, host:"localhost:27019"}]})' \
  >/dev/null 2>&1 || true
wait_primary

echo "==> Sessions + transactions integration test"
zig build runtime-integration-test
stop_mongo

echo "==> ALL BONGO LINUX/FLY VALIDATION TESTS PASSED"
