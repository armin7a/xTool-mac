#!/bin/bash
# Development: builds a debug binary and runs it against a throwaway test vault. Never touches your real vault.
#   Scripts/run_dev.sh            start the app against a copy of the test vault
#   Scripts/run_dev.sh tour <dir> walk through all screens and save a picture of each into <dir>
#   Scripts/run_dev.sh setup <dir> show the first-start screen and save a picture of it
set -euo pipefail
source "$(dirname "$0")/compile.sh"
ARCH="$(uname -m)"
compile_all "$ARCH" debug
BIN="$OUT/$ARCH-debug/xTool"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
VAULT="$WORK/Vault"
export XTOOL_VAULT_DIR="$VAULT"
export XTOOL_TEST_PASSWORD="xTool-Fixture-1 äöü"
case "${1:-}" in
tour|setup)
    export XTOOL_TEST_TOUR=1 XTOOL_TEST_OUT="$2"
    mkdir -p "$2"
    if [ "$1" = tour ]; then cp -R "$ROOT/Tests/Fixtures/vault-format-1" "$VAULT"; fi
    "$BIN"
    ;;
*)
    cp -R "$ROOT/Tests/Fixtures/vault-format-1" "$VAULT"
    echo "Test-Passwort: $XTOOL_TEST_PASSWORD"
    "$BIN"
    ;;
esac
