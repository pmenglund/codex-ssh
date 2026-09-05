#!/bin/bash
set -euo pipefail

# ssh-keygen accepts private keys and skips bad lines in a multi-line file.
# Validate public-key entries separately, allowing blank lines and comments.
valid_keys=0
comment_or_blank='^[[:space:]]*(#|$)'
while IFS= read -r key_line || [[ -n "$key_line" ]]; do
    if [[ "$key_line" =~ $comment_or_blank ]]; then continue; fi
    if ! printf '%s\n' "$key_line" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1; then
        echo 'Invalid SSH authorized key.' >&2
        exit 1
    fi
    valid_keys=$((valid_keys + 1))
done < "$1"

if [[ "$valid_keys" == 0 ]]; then
    echo 'No valid SSH authorized keys configured.' >&2
    exit 1
fi
