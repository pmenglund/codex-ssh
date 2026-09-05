#!/usr/bin/env bash
# Single-quoted commands expand in the target user/container shell.
# shellcheck disable=SC2016
# Supports macOS Bash 3.2 as well as current Bash.
set -euo pipefail

IMAGE="${1:-codex-ssh:test}"
PLATFORM="${PLATFORM:-}"
CONTAINER_NAME="codex-ssh-smoke-$$"
HOME_VOLUME="${CONTAINER_NAME}-home"
WORKSPACE_VOLUME="${CONTAINER_NAME}-workspace"
HOST_VOLUME="${CONTAINER_NAME}-host"
KEY_DIR="$(mktemp -d)"
DUMMY_API_KEY=sk-test-codex-ssh-not-a-real-key
PORT=''
CLIENT_KEY="$KEY_DIR/id_ed25519"

cleanup() {
    status=$?
    trap - EXIT
    docker rm -fv "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    docker volume rm "${HOME_VOLUME}" "${WORKSPACE_VOLUME}" "${HOST_VOLUME}" >/dev/null 2>&1 || true
    rm -rf "${KEY_DIR}"
    exit "$status"
}
trap cleanup EXIT

fail() { echo "$*" >&2; exit 1; }

docker_run() {
    if [[ -n "$PLATFORM" ]]; then
        docker run --platform "$PLATFORM" "$@"
    else
        docker run "$@"
    fi
}

start_container() {
    docker_run -d --name "$CONTAINER_NAME" \
        -p 127.0.0.1::22 \
        -v "$HOME_VOLUME:/home/codex" \
        -v "$WORKSPACE_VOLUME:/workspace" \
        -v "$HOST_VOLUME:/var/lib/sshd" \
        "$@" "$IMAGE" >/dev/null
}

remove_container() { docker rm -fv "$CONTAINER_NAME" >/dev/null; }

ssh_remote() {
    ssh -i "$CLIENT_KEY" -p "$PORT" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=2 \
        -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
        -o HostKeyAlias=codex-ssh-smoke -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KEY_DIR/known_hosts" codex@127.0.0.1 "$@"
}

wait_for_ssh() {
    PORT=$(docker port "$CONTAINER_NAME" 22/tcp | sed 's/.*://')
    for _ in $(seq 1 60); do
        if ssh_remote true >/dev/null 2>&1; then return; fi
        if [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == false ]]; then break; fi
        sleep 1
    done
    docker logs "$CONTAINER_NAME" >&2
    fail 'SSH did not become ready'
}

host_fingerprint() {
    docker exec "$CONTAINER_NAME" ssh-keygen -lf /var/lib/sshd/ssh_host_ed25519_key.pub | awk '{print $2}'
}

expect_start_failure() {
    expected=$1
    shift
    start_container "$@"
    for _ in $(seq 1 30); do
        if [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == false ]]; then break; fi
        sleep 1
    done
    [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == false ]] || fail 'Invalid configuration started successfully'
    [[ $(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME") != 0 ]] || fail 'Invalid configuration returned success'
    docker logs "$CONTAINER_NAME" > "$KEY_DIR/failure.log" 2>&1
    grep -q "$expected" "$KEY_DIR/failure.log" || { cat "$KEY_DIR/failure.log" >&2; fail 'Missing expected startup error'; }
    remove_container
}

ssh-keygen -q -t ed25519 -N '' -f "$KEY_DIR/id_ed25519"
PUBLIC_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
for volume in "$HOME_VOLUME" "$WORKSPACE_VOLUME" "$HOST_VOLUME"; do docker volume create "$volume" >/dev/null; done

# Inspect the image without running initialization.
docker_run --rm --entrypoint sh "$IMAGE" -c '
    for key in /etc/ssh/ssh_host_*_key /var/lib/sshd/ssh_host_*_key; do test ! -e "$key" || exit 1; done
    test -x /opt/codex/bin/codex-code-mode-host
    test -x /opt/codex/codex-path/rg
    test -x /opt/codex/codex-resources/bwrap
'
expect_start_failure 'No valid SSH authorized keys configured'
expect_start_failure 'AUTHORIZED_KEYS_FILE must name a readable regular file' -e AUTHORIZED_KEYS_FILE=/missing
expect_start_failure 'CODEX_HOME must not be set globally' -e CODEX_HOME=/home/codex
expect_start_failure 'CODEX_HOME must not be set globally' -e CODEX_HOME=
expect_start_failure 'HOME must be' -e HOME=/home/codex

start_container -e AUTHORIZED_KEYS="$PUBLIC_KEY" -e OPENAI_API_KEY="$DUMMY_API_KEY"
# Pin the server's public key through the trusted Docker API, not the network.
for _ in $(seq 1 60); do
    if docker exec "$CONTAINER_NAME" cat /var/lib/sshd/ssh_host_ed25519_key.pub > "$KEY_DIR/host.pub" 2>/dev/null; then break; fi
    sleep 1
done
printf 'codex-ssh-smoke %s\n' "$(cat "$KEY_DIR/host.pub")" > "$KEY_DIR/known_hosts"
wait_for_ssh
original_fingerprint=$(host_fingerprint)

ssh_remote 'go version && git --version && codex --version'
ssh_remote 'test "$HOME" = /home/codex && test "$CODEX_HOME" = /home/codex/.codex && test -z "${OPENAI_API_KEY+x}"'
docker exec --user codex "$CONTAINER_NAME" sh -c 'test "$HOME" = /home/codex && test "${CODEX_HOME:-$HOME/.codex}" = /home/codex/.codex && codex login status' > /dev/null 2>&1
# Dummy key login only stores credentials; no provider requests are made.
ssh_remote 'codex login status' > "$KEY_DIR/login.log" 2>&1
grep -qi 'api key' "$KEY_DIR/login.log"
ssh_remote 'test "$(stat -c %u:%a "$CODEX_HOME/auth.json")" = 1000:600'
ssh_remote 'test -w /home/codex && test -w /workspace && printf home >~/persist-home && printf workspace >/workspace/persist-workspace'
docker exec "$CONTAINER_NAME" sh -ec '
    test "$(stat -c %u:%a /var/lib/sshd/ssh_host_ed25519_key)" = 0:600
    touch /home/codex/foreign-owned /workspace/foreign-owned
    chown 1234:1234 /home/codex/foreign-owned /workspace/foreign-owned
    chmod 640 /home/codex/foreign-owned /workspace/foreign-owned
'
ssh_remote 'test ! -r /var/lib/sshd/ssh_host_ed25519_key'
docker logs "$CONTAINER_NAME" > "$KEY_DIR/container.log" 2>&1
if grep -Fq "$DUMMY_API_KEY" "$KEY_DIR/container.log"; then fail 'API key leaked to container logs'; fi

sshd_config=$(docker exec "$CONTAINER_NAME" sshd -T)
for option in 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'hostkey /var/lib/sshd/ssh_host_ed25519_key'; do
    grep -qx "$option" <<< "$sshd_config"
done
if ssh -i "$KEY_DIR/id_ed25519" -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=2 \
    -o HostKeyAlias=codex-ssh-smoke -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KEY_DIR/known_hosts" root@127.0.0.1 true >/dev/null 2>&1; then
    fail 'root SSH login unexpectedly succeeded'
fi
if ssh -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=2 \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o HostKeyAlias=codex-ssh-smoke -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KEY_DIR/known_hosts" codex@127.0.0.1 true >/dev/null 2>&1; then
    fail 'password SSH login unexpectedly succeeded'
fi
# A user-installed executable must never be selected by root during startup.
ssh_remote 'mkdir -p ~/go/bin; printf "#!/bin/sh\n/usr/bin/touch /tmp/root-path-hijacked\n" >~/go/bin/runuser; chmod 755 ~/go/bin/runuser; cp ~/go/bin/runuser ~/go/bin/ssh-keygen'
docker exec "$CONTAINER_NAME" sh -c 'test "$HOME" = /root && test -z "${CODEX_HOME+x}" && test "$(command -v ssh-keygen)" = /usr/bin/ssh-keygen'
[[ $(host_fingerprint) == "$original_fingerprint" ]] || fail 'Root docker exec selected user-controlled ssh-keygen'
docker exec "$CONTAINER_NAME" test ! -e /tmp/root-path-hijacked
remove_container

# Explicit bad inputs must fail despite persisted keys and must not destroy them.
expect_start_failure 'OPENAI_API_KEY must not be empty' -e OPENAI_API_KEY=
expect_start_failure 'AUTHORIZED_KEYS_FILE must name a readable regular file' -e AUTHORIZED_KEYS_FILE=/missing
expect_start_failure 'AUTHORIZED_KEYS_FILE must name a readable regular file' -e AUTHORIZED_KEYS_FILE=/missing -e AUTHORIZED_KEYS="$PUBLIC_KEY"
expect_start_failure 'No valid SSH authorized keys configured' -e AUTHORIZED_KEYS=''
expect_start_failure 'Invalid SSH authorized key' -e AUTHORIZED_KEYS='not a public key'
expect_start_failure 'Invalid SSH authorized key' -e AUTHORIZED_KEYS="$(cat "$KEY_DIR/id_ed25519")"
expect_start_failure 'Invalid SSH authorized key' -e AUTHORIZED_KEYS="$(printf '%s\ninvalid-key\n' "$PUBLIC_KEY")"

start_container
wait_for_ssh
docker exec "$CONTAINER_NAME" test ! -e /tmp/root-path-hijacked
[[ $(host_fingerprint) == "$original_fingerprint" ]] || fail 'SSH host identity changed after replacement'
ssh_remote 'test "$(cat ~/persist-home)" = home && test "$(cat /workspace/persist-workspace)" = workspace && codex login status' > /dev/null 2>&1
for path in /home/codex/foreign-owned /workspace/foreign-owned; do
    [[ $(docker exec "$CONTAINER_NAME" stat -c %u:%g:%a "$path") == 1234:1234:640 ]] || fail 'Startup changed existing file ownership or mode'
done
remove_container

# Missing or stale public state is reconstructed from the same private key.
for public_state in missing mismatched; do
    if [[ "$public_state" == missing ]]; then
        docker_run --rm --entrypoint rm -v "$HOST_VOLUME:/var/lib/sshd" "$IMAGE" /var/lib/sshd/ssh_host_ed25519_key.pub
    else
        docker_run --rm --entrypoint sh -v "$HOST_VOLUME:/var/lib/sshd" -e OTHER_PUBLIC_KEY="$PUBLIC_KEY" "$IMAGE" -c 'printf "%s\n" "$OTHER_PUBLIC_KEY" >/var/lib/sshd/ssh_host_ed25519_key.pub'
    fi
    start_container
    wait_for_ssh
    [[ $(host_fingerprint) == "$original_fingerprint" ]] || fail 'Stored host fingerprint disagrees with SSH identity'
    docker exec "$CONTAINER_NAME" sh -c 'test "$(ssh-keygen -y -f /var/lib/sshd/ssh_host_ed25519_key)" = "$(cat /var/lib/sshd/ssh_host_ed25519_key.pub)"'
    remove_container
done

# Mounted key files, including a root-readable secret, work without giving root
# permission to write into the user's home directory.
start_container -v "$KEY_DIR/id_ed25519.pub:/run/secrets/authorized_keys:ro"
wait_for_ssh
remove_container
start_container -v "$KEY_DIR/id_ed25519.pub:/run/secrets/custom:ro" -e AUTHORIZED_KEYS_FILE=/run/secrets/custom
wait_for_ssh
remove_container

# Rotation accepts the replacement key and rejects the previous key.
ssh-keygen -q -t ed25519 -N '' -f "$KEY_DIR/replacement"
start_container -e AUTHORIZED_KEYS="$(printf '# replacement key\n\nrestrict %s\n' "$(cat "$KEY_DIR/replacement.pub")")"
CLIENT_KEY="$KEY_DIR/replacement"
wait_for_ssh
CLIENT_KEY="$KEY_DIR/id_ed25519"
if ssh_remote true >/dev/null 2>&1; then fail 'Previous SSH key remained authorized after rotation'; fi
remove_container

# Unwritable mount roots fail instead of being changed to UID 1000.
docker_run --rm --entrypoint sh -v "$WORKSPACE_VOLUME:/workspace" "$IMAGE" -c 'chown 1234:1234 /workspace; chmod 700 /workspace'
expect_start_failure '/workspace must be writable by UID 1000'
[[ $(docker_run --rm --entrypoint stat -v "$WORKSPACE_VOLUME:/workspace" "$IMAGE" -c %u:%g:%a /workspace) == 1234:1234:700 ]] || fail 'Startup rewrote mount-root permissions'
docker_run --rm --entrypoint sh -v "$WORKSPACE_VOLUME:/workspace" "$IMAGE" -c 'chown 1000:1000 /workspace; chmod 755 /workspace'

# A fresh deployment has a distinct identity even with the same image/home.
fresh_fingerprint=$(docker_run --rm -v "$HOME_VOLUME:/home/codex" -v "$WORKSPACE_VOLUME:/workspace" "$IMAGE" ssh-keygen -lf /var/lib/sshd/ssh_host_ed25519_key.pub | awk '{print $2}')
[[ "$fresh_fingerprint" != "$original_fingerprint" ]] || fail 'Fresh deployment reused SSH host identity'
echo "Smoke tests passed (${PLATFORM:-default}, Bash $BASH_VERSION)."
