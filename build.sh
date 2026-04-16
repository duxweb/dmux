#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")" && pwd)"

if [[ -z "${DMUX_VERSION:-}" ]]; then
  if git -C "${root_dir}" describe --tags --abbrev=0 >/dev/null 2>&1; then
    export DMUX_VERSION="$(git -C "${root_dir}" describe --tags --abbrev=0 | sed 's/^v//')"
  else
    export DMUX_VERSION="0.1.7"
  fi
fi

if [[ -z "${DMUX_PACKAGE_VERSION:-}" ]]; then
  export DMUX_PACKAGE_VERSION="${DMUX_VERSION}-debug"
fi

export DMUX_BUILD_NUMBER="${DMUX_BUILD_NUMBER:-1}"
export DMUX_CONFIGURATION="Debug"
export DMUX_LOG_PROFILE="verbose"
export DMUX_APP_VARIANT_SUFFIX="-debug"
export DMUX_APP_DISPLAY_NAME="Codux-debug"
export DMUX_APP_BUNDLE_NAME="Codux-debug"
export DMUX_BUNDLE_IDENTIFIER_SUFFIX=".debug"
exec "${root_dir}/scripts/release/package-local-dmg.sh"
