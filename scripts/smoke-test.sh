#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-codex-ssh:test}"
PLATFORM="${PLATFORM:-}"
PLATFORM_LABEL="${PLATFORM:-default}"
CONTAINER_NAME="codex-ssh-smoke-${PLATFORM_LABEL//\//-}-$$"
HOME_VOLUME="${CONTAINER_NAME}-home"
WORKSPACE_VOLUME="${CONTAINER_NAME}-workspace"
KEY_DIR="$(mktemp -d)"
PORT_FILE="${KEY_DIR}/port"

cleanup() {
    docker rm -fv "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    docker volume rm "${HOME_VOLUME}" "${WORKSPACE_VOLUME}" >/dev/null 2>&1 || true
    rm -rf "${KEY_DIR}"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "${KEY_DIR}/id_ed25519"
docker volume create "${HOME_VOLUME}" >/dev/null
docker volume create "${WORKSPACE_VOLUME}" >/dev/null

start_container() {
    local auth_args=()
    local platform_args=()
    if [[ "${1:-with-keys}" == "with-keys" ]]; then
        auth_args=(-e AUTHORIZED_KEYS="$(cat "${KEY_DIR}/id_ed25519.pub")")
    fi
    if [[ -n "${PLATFORM}" ]]; then
        platform_args=(--platform "${PLATFORM}")
    fi

    docker run -d \
        --name "${CONTAINER_NAME}" \
        "${platform_args[@]}" \
        -p 127.0.0.1::22 \
        -v "${HOME_VOLUME}:/home/codex" \
        -v "${WORKSPACE_VOLUME}:/workspace" \
        "${auth_args[@]}" \
        "${IMAGE}" >/dev/null

    docker port "${CONTAINER_NAME}" 22/tcp | sed 's/.*://' > "${PORT_FILE}"
}

wait_for_ssh() {
    local ready=0
    for _ in $(seq 1 60); do
        if ssh \
            -i "${KEY_DIR}/id_ed25519" \
            -p "$(cat "${PORT_FILE}")" \
            -o BatchMode=yes \
            -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=2 \
            codex@127.0.0.1 'true' >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
    done

    if [[ "${ready}" != "1" ]]; then
        docker logs "${CONTAINER_NAME}" >&2 || true
        echo "SSH did not become ready" >&2
        exit 1
    fi
}

ssh_remote() {
    ssh \
        -i "${KEY_DIR}/id_ed25519" \
        -p "$(cat "${PORT_FILE}")" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        codex@127.0.0.1 \
        "$@"
}

start_container with-keys
wait_for_ssh

ssh_remote 'go version'
ssh_remote 'git --version'
ssh_remote 'codex --version'
ssh_remote 'test -w /home/codex && test -w /workspace'
ssh_remote 'printf home >/home/codex/persist-home && printf workspace >/workspace/persist-workspace'

sshd_config="$(docker exec "${CONTAINER_NAME}" sshd -T)"
grep -q '^permitrootlogin no$' <<<"${sshd_config}"
grep -q '^passwordauthentication no$' <<<"${sshd_config}"
grep -q '^kbdinteractiveauthentication no$' <<<"${sshd_config}"

if ssh \
    -i "${KEY_DIR}/id_ed25519" \
    -p "$(cat "${PORT_FILE}")" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1 'true' >/dev/null 2>&1; then
    echo "root SSH login unexpectedly succeeded" >&2
    exit 1
fi

if ssh \
    -p "$(cat "${PORT_FILE}")" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    codex@127.0.0.1 'true' >/dev/null 2>&1; then
    echo "password SSH login unexpectedly succeeded" >&2
    exit 1
fi

docker rm -f "${CONTAINER_NAME}" >/dev/null

start_container without-keys
wait_for_ssh
ssh_remote 'test "$(cat /home/codex/persist-home)" = home && test "$(cat /workspace/persist-workspace)" = workspace'
