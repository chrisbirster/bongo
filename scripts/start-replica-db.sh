#!/usr/bin/env bash
set -euo pipefail

MONGO_IMAGE="${MONGO_IMAGE:-mongo:8.0}"

docker rm -f mongodb-rs >/dev/null 2>&1 || true

docker run -d \
  --name mongodb-rs \
  -p 27019:27017 \
  "$MONGO_IMAGE" \
  --replSet rs0 \
  --bind_ip_all

for attempt in $(seq 1 60); do
  if docker exec mongodb-rs mongosh --quiet --eval 'quit(db.runCommand({ping:1}).ok === 1 ? 0 : 1)' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker exec mongodb-rs mongosh --quiet --eval '
try {
  rs.status();
} catch (_) {
  rs.initiate({_id:"rs0", members:[{_id:0, host:"localhost:27017"}]});
}
' >/dev/null

for attempt in $(seq 1 60); do
  if docker exec mongodb-rs mongosh --quiet --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' >/dev/null 2>&1; then
    echo "Replica-set MongoDB fixture ready on localhost:27019"
    echo "Run: zig build runtime-integration-test"
    exit 0
  fi
  sleep 1
done

echo "Replica-set MongoDB fixture failed to elect a primary" >&2
docker logs mongodb-rs >&2 || true
exit 1
