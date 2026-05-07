#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Validates that every test name listed in the config/*.txt files exists
# as a Go test function ("func <TestName>(") in the azure-linux-image-tools codebase.
#
# Clones the repo to a temporary directory, runs the checks, then cleans up.
#
# Usage: check-config-test-names.sh --config-dir <path>

set -euo pipefail

usage() {
    echo "Usage: $0 --config-dir <path>" >&2
    exit 1
}

CONFIG_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir)
            [[ $# -lt 2 ]] && usage
            CONFIG_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "$CONFIG_DIR" ]]; then
    echo "Error: --config-dir is required." >&2
    usage
fi

if [[ ! -d "$CONFIG_DIR" ]]; then
    echo "Error: config directory '$CONFIG_DIR' does not exist." >&2
    exit 1
fi

REPO_URL="https://github.com/microsoft/azure-linux-image-tools.git"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CODEBASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CODEBASE_DIR"' EXIT

echo "Cloning $REPO_URL into temporary directory ..."
git clone --depth 1 --quiet "$REPO_URL" "$CODEBASE_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

exit_code=0

for config_file in "$CONFIG_DIR"/*; do
    file_basename="$(basename "$config_file")"
    echo "Checking config/$file_basename ..."

    while IFS= read -r test_name; do
        if ! grep -rq "func ${test_name}(" "$CODEBASE_DIR" --include='*.go' 2>/dev/null; then
            echo -e "  ${RED}MISSING${NC}: $test_name  (not found in codebase)"
            exit_code=1
        fi
    done < "$config_file"
done

if [[ "$exit_code" -eq 0 ]]; then
    echo -e "${GREEN}All test names found in the codebase.${NC}"
else
    echo -e "${RED}Some test names were not found. See above for details.${NC}" >&2
fi

exit "$exit_code"
