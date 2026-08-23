#!/usr/bin/env bash
set -euo pipefail

MONGO_IMAGE="${MONGO_IMAGE:-mongo:8.0}"

docker run -d \
  --name mongodb \
  -p 27017:27017 \
  -v mongo_data:/data/db \
  -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD=secretpassword \
  "$MONGO_IMAGE"
