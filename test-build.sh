#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")" && pwd)"
exec "${root_dir}/scripts/release/run-test-build.sh" "$@"
