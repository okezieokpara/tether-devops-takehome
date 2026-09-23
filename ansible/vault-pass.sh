#!/bin/sh
# Vault password: $ANSIBLE_VAULT_PASSWORD or ansible/.vault_pass (local, see `make vault`).
if [ -n "$ANSIBLE_VAULT_PASSWORD" ]; then
  printf '%s\n' "$ANSIBLE_VAULT_PASSWORD"
elif [ -f "$(dirname "$0")/.vault_pass" ]; then
  cat "$(dirname "$0")/.vault_pass"
else
  echo "No vault password: set ANSIBLE_VAULT_PASSWORD or create ansible/.vault_pass" >&2
  exit 1
fi
