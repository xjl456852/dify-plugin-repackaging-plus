#!/usr/bin/env bash
# author: xiejianglei
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DIFY_TARGET_ARCH=aarch64
exec "$SCRIPT_DIR/plugin_repackaging.sh" "$@"
