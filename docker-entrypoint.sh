#!/bin/bash
# Single-quoted commands expand in the target user/container shell.
# shellcheck disable=SC2016
set -euo pipefail
# Startup runs as root; never resolve commands from the user's tooling directories.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

fail() {
    echo "$*" >&2
    exit 1
}

# These paths must agree with passwd and sshd's SetEnv configuration.
[[ "${HOME-/root}" == /root ]] || fail 'HOME must be /root for the container root process.'
[[ "${CODEX_HOME+set}" != set ]] || fail 'CODEX_HOME must not be set globally; Codex uses each user home.'
[[ "${CODEX_USER-codex}" == codex ]] || fail 'The SSH user must be codex.'
[[ "${WORKSPACE-/workspace}" == /workspace ]] || fail 'The workspace must be /workspace.'

as_codex() {
    runuser -u codex -- env HOME=/home/codex CODEX_HOME=/home/codex/.codex "$@"
}

if [[ "${OPENAI_API_KEY+set}" == set ]]; then
    [[ -n "${OPENAI_API_KEY//[[:space:]]/}" ]] || fail 'OPENAI_API_KEY must not be empty when explicitly set.'
fi

# Validate explicit configuration even when inline keys take precedence.
if [[ "${AUTHORIZED_KEYS_FILE+set}" == set ]]; then
    [[ -f "${AUTHORIZED_KEYS_FILE}" && -r "${AUTHORIZED_KEYS_FILE}" ]] || fail 'AUTHORIZED_KEYS_FILE must name a readable regular file.'
fi

mkdir -p /run/sshd
as_codex test -w /home/codex || fail '/home/codex must be writable by UID 1000; prepare bind-mount permissions before starting.'
as_codex test -w /workspace || fail '/workspace must be writable by UID 1000; prepare bind-mount permissions before starting.'
# Never repair ownership recursively, or write into user-controlled paths as root.
as_codex bash -c 'set -e; umask 077; mkdir -p "$HOME/.ssh" "$CODEX_HOME"; chmod 700 "$HOME/.ssh" "$CODEX_HOME"'

write_authorized_keys() {
    as_codex bash -c '
        set -euo pipefail
        umask 077
        key_file=$(mktemp "$HOME/.ssh/authorized_keys.XXXXXX")
        trap '\''rm -f "$key_file"'\'' EXIT
        sed "/^[[:space:]]*$/d" > "$key_file"
        validate-authorized-keys "$key_file"
        mv -fT "$key_file" "$HOME/.ssh/authorized_keys"
    '
}

if [[ "${AUTHORIZED_KEYS+set}" == set ]]; then
    printf '%s\n' "${AUTHORIZED_KEYS}" | write_authorized_keys
elif [[ "${AUTHORIZED_KEYS_FILE+set}" == set ]]; then
    write_authorized_keys < "${AUTHORIZED_KEYS_FILE}"
elif [[ -e /run/secrets/authorized_keys ]]; then
    [[ -f /run/secrets/authorized_keys && -r /run/secrets/authorized_keys ]] || fail '/run/secrets/authorized_keys must be a readable regular file.'
    write_authorized_keys < /run/secrets/authorized_keys
fi
as_codex bash -c 'test -s "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys" && validate-authorized-keys "$HOME/.ssh/authorized_keys"' || fail 'No valid SSH authorized keys configured.'

# Keep server identity outside the user's writable home volume.
[[ -d /var/lib/sshd && ! -L /var/lib/sshd && "$(stat -c %u /var/lib/sshd)" == 0 ]] || fail '/var/lib/sshd must be a root-owned directory.'
chmod 700 /var/lib/sshd
host_key=/var/lib/sshd/ssh_host_ed25519_key
for host_file in "$host_key" "$host_key.pub"; do
    [[ ! -L "$host_file" ]] || fail 'SSH host key files must not be symbolic links.'
    if [[ -e "$host_file" ]]; then
        [[ -f "$host_file" && "$(stat -c %u "$host_file")" == 0 && "$(stat -c %h "$host_file")" == 1 ]] || fail 'SSH host key files must be root-owned regular files with one link.'
    fi
done
if [[ ! -e "$host_key" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$host_key"
fi
chmod 600 "$host_key"
# Derive public state from the private key, including after interrupted setup.
host_public=$(ssh-keygen -y -P '' -f "$host_key")
host_public_file=$(mktemp "$host_key.pub.XXXXXX")
trap 'rm -f "$host_public_file"' EXIT
printf '%s\n' "$host_public" > "$host_public_file"
chmod 644 "$host_public_file"
mv -fT "$host_public_file" "$host_key.pub"
trap - EXIT

if [[ "${OPENAI_API_KEY+set}" == set ]]; then
    # Login is local credential storage; the key is never placed in argv or logs.
    printf '%s' "$OPENAI_API_KEY" | as_codex codex -c 'cli_auth_credentials_store="file"' login --with-api-key
fi
unset OPENAI_API_KEY AUTHORIZED_KEYS

exec "$@"
