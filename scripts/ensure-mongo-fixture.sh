#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

MONGO_IMAGE="${MONGO_IMAGE:-mongo:latest}"
FIXTURE_VERSION="3"

die() {
    echo "error: $*" >&2
    exit 1
}

require_tools() {
    command -v docker >/dev/null 2>&1 || die "docker is required"
    docker info >/dev/null 2>&1 || die "docker is not running"
    command -v openssl >/dev/null 2>&1 || die "openssl is required"
}

ensure_image() {
    if ! docker image inspect "$MONGO_IMAGE" >/dev/null 2>&1; then
        echo "Pulling $MONGO_IMAGE..."
        docker pull "$MONGO_IMAGE" >/dev/null
    fi
}

expected_image_id() {
    docker image inspect --format '{{.Id}}' "$MONGO_IMAGE"
}

container_image_id() {
    docker inspect --format '{{.Image}}' "$1" 2>/dev/null
}

container_label() {
    docker inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null
}

container_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

container_current() {
    local name="$1"
    local fixture="$2"

    docker inspect "$name" >/dev/null 2>&1 || return 1
    container_running "$name" || return 1
    [[ "$(container_label "$name" "io.bongo.fixture")" == "$fixture" ]] || return 1
    [[ "$(container_label "$name" "io.bongo.fixture-version")" == "$FIXTURE_VERSION" ]] || return 1
    [[ "$(container_image_id "$name")" == "$(expected_image_id)" ]] || return 1
    return 0
}

wait_for() {
    local description="$1"
    shift

    for _ in $(seq 1 60); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "$description failed to become ready" >&2
    return 1
}

standalone_ready() {
    docker exec mongodb mongosh \
        --quiet \
        --username admin \
        --password secretpassword \
        --authenticationDatabase admin \
        --eval 'quit(db.runCommand({ping:1}).ok === 1 ? 0 : 1)'
}

replica_ready() {
    docker exec mongodb-rs mongosh \
        --quiet \
        --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)'
}

sdam_ready() {
    docker exec mongodb-sdam mongosh \
        --quiet \
        --port 27021 \
        --eval '
            try {
                const status = rs.status();
                quit(status.members.length === 3 && status.members.some(m => m.stateStr === "PRIMARY") ? 0 : 1);
            } catch (_) {
                quit(1);
            }
        '
}

tls_ready() {
    docker exec mongodb-tls mongosh \
        --quiet \
        --tls \
        --tlsAllowInvalidCertificates \
        --username admin \
        --password secretpassword \
        --authenticationDatabase admin \
        --eval 'quit(db.runCommand({ping:1}).ok === 1 ? 0 : 1)'
}

ensure_standalone() {
    if container_current mongodb standalone && standalone_ready >/dev/null 2>&1; then
        echo "MongoDB standalone fixture ready on localhost:27017"
        return
    fi

    echo "Recreating MongoDB standalone fixture..."
    docker rm -f mongodb >/dev/null 2>&1 || true

    docker run -d \
        --name mongodb \
        --label io.bongo.fixture=standalone \
        --label io.bongo.fixture-version="$FIXTURE_VERSION" \
        -p 27017:27017 \
        -e MONGO_INITDB_ROOT_USERNAME=admin \
        -e MONGO_INITDB_ROOT_PASSWORD=secretpassword \
        "$MONGO_IMAGE" \
        >/dev/null

    if ! wait_for "MongoDB standalone fixture" standalone_ready; then
        docker logs mongodb >&2 || true
        return 1
    fi
    echo "MongoDB standalone fixture ready on localhost:27017"
}

ensure_replica() {
    if container_current mongodb-rs replica && replica_ready >/dev/null 2>&1; then
        echo "MongoDB replica-set fixture ready on localhost:27019"
        return
    fi

    echo "Recreating MongoDB replica-set fixture..."
    docker rm -f mongodb-rs >/dev/null 2>&1 || true

    docker run -d \
        --name mongodb-rs \
        --label io.bongo.fixture=replica \
        --label io.bongo.fixture-version="$FIXTURE_VERSION" \
        -p 27019:27017 \
        "$MONGO_IMAGE" \
        --replSet rs0 \
        --bind_ip_all \
        >/dev/null

    wait_for \
        "MongoDB replica-set startup" \
        docker exec mongodb-rs mongosh \
            --quiet \
            --eval 'quit(db.runCommand({ping:1}).ok === 1 ? 0 : 1)'

    docker exec mongodb-rs mongosh --quiet --eval '
        try {
            rs.status();
        } catch (_) {
            rs.initiate({
                _id: "rs0",
                members: [
                    { _id: 0, host: "localhost:27017" }
                ]
            });
        }
    ' >/dev/null

    if ! wait_for "MongoDB replica-set election" replica_ready; then
        docker logs mongodb-rs >&2 || true
        return 1
    fi
    echo "MongoDB replica-set fixture ready on localhost:27019"
}

ensure_sdam() {
    if container_current mongodb-sdam sdam && sdam_ready >/dev/null 2>&1; then
        echo "MongoDB 3-member SDAM fixture ready on localhost:27021-27023"
        return
    fi

    echo "Recreating MongoDB 3-member SDAM fixture..."
    docker rm -f mongodb-sdam >/dev/null 2>&1 || true

    docker run -d \
        --name mongodb-sdam \
        --label io.bongo.fixture=sdam \
        --label io.bongo.fixture-version="$FIXTURE_VERSION" \
        -p 27021:27021 \
        -p 27022:27022 \
        -p 27023:27023 \
        "$MONGO_IMAGE" \
        bash -lc '
            set -e
            mkdir -p /data/rs0-0 /data/rs0-1 /data/rs0-2
            mongod --replSet rs0 --port 27021 --dbpath /data/rs0-0 --bind_ip_all --setParameter enableTestCommands=1 --fork --logpath /tmp/rs0-0.log
            mongod --replSet rs0 --port 27022 --dbpath /data/rs0-1 --bind_ip_all --setParameter enableTestCommands=1 --fork --logpath /tmp/rs0-1.log
            mongod --replSet rs0 --port 27023 --dbpath /data/rs0-2 --bind_ip_all --setParameter enableTestCommands=1 --fork --logpath /tmp/rs0-2.log
            tail -f /dev/null
        ' \
        >/dev/null

    wait_for \
        "MongoDB SDAM member startup" \
        docker exec mongodb-sdam mongosh \
            --quiet \
            --port 27021 \
            --eval 'quit(db.runCommand({ping:1}).ok === 1 ? 0 : 1)'

    docker exec mongodb-sdam mongosh --quiet --port 27021 --eval '
        try {
            rs.status();
        } catch (_) {
            rs.initiate({
                _id: "rs0",
                members: [
                    { _id: 0, host: "localhost:27021", priority: 2 },
                    { _id: 1, host: "localhost:27022", priority: 1 },
                    { _id: 2, host: "localhost:27023", priority: 1 }
                ]
            });
        }
    ' >/dev/null

    if ! wait_for "MongoDB SDAM replica-set election" sdam_ready; then
        docker logs mongodb-sdam >&2 || true
        return 1
    fi
    echo "MongoDB 3-member SDAM fixture ready on localhost:27021-27023"
}

tls_cert_current() {
    local cert="$root/.bongo-tls/server-cert.pem"
    [[ -f "$cert" ]] || return 1
    openssl x509 -checkend 3600 -noout -in "$cert" >/dev/null 2>&1
}

generate_tls_certificate() {
    local tls_dir="$root/.bongo-tls"
    rm -rf "$tls_dir"
    mkdir -p "$tls_dir"

    openssl req \
        -x509 \
        -newkey rsa:2048 \
        -nodes \
        -keyout "$tls_dir/server-key.pem" \
        -out "$tls_dir/server-cert.pem" \
        -days 2 \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        >/dev/null 2>&1

    cat "$tls_dir/server-key.pem" "$tls_dir/server-cert.pem" > "$tls_dir/mongodb.pem"
    chmod 644 "$tls_dir/mongodb.pem" "$tls_dir/server-cert.pem"
}

ensure_tls() {
    if container_current mongodb-tls tls &&
       tls_cert_current &&
       tls_ready >/dev/null 2>&1; then
        echo "MongoDB TLS fixture ready on localhost:27018"
        return
    fi

    echo "Recreating MongoDB TLS fixture..."
    docker rm -f mongodb-tls >/dev/null 2>&1 || true
    generate_tls_certificate

    docker run -d \
        --name mongodb-tls \
        --label io.bongo.fixture=tls \
        --label io.bongo.fixture-version="$FIXTURE_VERSION" \
        -p 27018:27017 \
        -v "$root/.bongo-tls:/tls:ro" \
        -e MONGO_INITDB_ROOT_USERNAME=admin \
        -e MONGO_INITDB_ROOT_PASSWORD=secretpassword \
        "$MONGO_IMAGE" \
        --tlsMode requireTLS \
        --tlsCertificateKeyFile /tls/mongodb.pem \
        --tlsCAFile /tls/server-cert.pem \
        --tlsAllowConnectionsWithoutCertificates \
        --bind_ip_all \
        >/dev/null

    if ! wait_for "MongoDB TLS fixture" tls_ready; then
        docker logs mongodb-tls >&2 || true
        return 1
    fi
    echo "MongoDB TLS fixture ready on localhost:27018"
}

clean() {
    docker rm -f \
        mongodb \
        mongodb-rs \
        mongodb-sdam \
        mongodb-tls \
        >/dev/null 2>&1 || true
    rm -rf "$root/.bongo-tls"
    echo "Bongo MongoDB fixtures removed"
}

status_one() {
    local name="$1"
    if ! docker inspect "$name" >/dev/null 2>&1; then
        printf '%-14s %s\n' "$name" "missing"
        return
    fi
    printf '%-14s running=%-5s image=%s fixture=%s\n' \
        "$name" \
        "$(docker inspect --format '{{.State.Running}}' "$name")" \
        "$(docker inspect --format '{{.Config.Image}}' "$name")" \
        "$(container_label "$name" "io.bongo.fixture")"
}

status() {
    status_one mongodb
    status_one mongodb-tls
    status_one mongodb-rs
    status_one mongodb-sdam
}

require_tools
ensure_image

case "${1:-}" in
    standalone) ensure_standalone ;;
    tls) ensure_tls ;;
    replica) ensure_replica ;;
    sdam) ensure_sdam ;;
    status) status ;;
    reset)
        clean
        ensure_standalone
        ensure_tls
        ensure_replica
        ensure_sdam
        ;;
    clean) clean ;;
    *)
        echo "usage: $0 {standalone|tls|replica|sdam|status|reset|clean}" >&2
        exit 2
        ;;
esac
