#!/usr/bin/env bash
#
# build-image - build the zek image under the GHCR name CI publishes and
# export IMAGE for make and the later login/push steps.
#
# CI only: needs GITHUB_REPOSITORY and GITHUB_ENV from the runner. Shared
# by build-and-test.yml and main.yml so tests and publishing build the
# exact same way.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

IMAGE="ghcr.io/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
export IMAGE="${IMAGE,,}"
echo "IMAGE=${IMAGE}" >> "${GITHUB_ENV:?GITHUB_ENV is required}"
make build
