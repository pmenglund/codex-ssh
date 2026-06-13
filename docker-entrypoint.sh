#!/usr/bin/env bash
set -euo pipefail

CODEX_USER="${CODEX_USER:-codex}"
CODEX_HOME="${CODEX_HOME:-/home/codex}"
WORKSPACE="${WORKSPACE:-/workspace}"
AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-}"
DEFAULT_AUTHORIZED_KEYS_FILE="/run/secrets/authorized_keys"
SSH_DIR="${CODEX_HOME}/.ssh"
AUTHORIZED_KEYS_PATH="${SSH_DIR}/authorized_keys"

mkdir -p /run/sshd "${SSH_DIR}" "${CODEX_HOME}/.codex" "${WORKSPACE}"
touch "${AUTHORIZED_KEYS_PATH}"
chmod 700 "${SSH_DIR}"
chmod 600 "${AUTHORIZED_KEYS_PATH}"

if [[ -n "${AUTHORIZED_KEYS:-}" ]]; then
    printf '%s\n' "${AUTHORIZED_KEYS}" | sed '/^[[:space:]]*$/d' > "${AUTHORIZED_KEYS_PATH}"
elif [[ -n "${AUTHORIZED_KEYS_FILE}" && -f "${AUTHORIZED_KEYS_FILE}" ]]; then
    sed '/^[[:space:]]*$/d' "${AUTHORIZED_KEYS_FILE}" > "${AUTHORIZED_KEYS_PATH}"
elif [[ -f "${DEFAULT_AUTHORIZED_KEYS_FILE}" ]]; then
    sed '/^[[:space:]]*$/d' "${DEFAULT_AUTHORIZED_KEYS_FILE}" > "${AUTHORIZED_KEYS_PATH}"
fi

if [[ ! -s "${AUTHORIZED_KEYS_PATH}" ]]; then
    echo "No SSH authorized keys configured." >&2
    echo "Set AUTHORIZED_KEYS, mount /run/secrets/authorized_keys, or mount an existing ${AUTHORIZED_KEYS_PATH}." >&2
    exit 1
fi

ssh-keygen -A
chown -R "${CODEX_USER}:${CODEX_USER}" "${CODEX_HOME}" "${WORKSPACE}"

exec "$@"
