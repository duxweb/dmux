#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [version]" >&2
  exit 1
fi

latest_tag="$(git tag --sort=-version:refname | head -1 || true)"
latest_version="${latest_tag#v}"

echo "Current latest version: ${latest_version:-none}"

if [[ $# -eq 1 ]]; then
  raw_version="$1"
else
  read -r -p "Next release version: " raw_version
fi

version="${raw_version#v}"
if [[ -z "${version}" ]]; then
  echo "Release version is required." >&2
  exit 1
fi

if [[ ! "${version}" =~ ^[0-9]+(\.[0-9]+){2}([.-][A-Za-z0-9]+)?$ ]]; then
  echo "Invalid version format: ${version}" >&2
  exit 1
fi

tag="v${version}"
branch="$(git branch --show-current)"

if [[ "${branch}" != "main" ]]; then
  echo "release must be created from main. current branch: ${branch}" >&2
  exit 1
fi

if [[ ! -f "CHANGELOG.md" ]]; then
  echo "CHANGELOG.md not found." >&2
  exit 1
fi

if ! notes="$(bash scripts/release/extract-release-notes.sh "${version}" CHANGELOG.md 2>/dev/null)"; then
  echo "CHANGELOG.md does not contain a usable entry for ${version}." >&2
  exit 1
fi

if [[ -n "$(git status --short)" ]]; then
  echo "working tree is not clean. commit or stash changes before releasing ${tag}." >&2
  exit 1
fi

head_commit="$(git rev-parse HEAD)"
existing_tag_commit="$(git rev-parse -q --verify "${tag}^{commit}" 2>/dev/null || true)"

if [[ -n "${existing_tag_commit}" && "${existing_tag_commit}" != "${head_commit}" ]]; then
  echo "${tag} already exists and points to ${existing_tag_commit}, not HEAD ${head_commit}." >&2
  exit 1
fi

echo
echo "Release summary"
echo "- branch: ${branch}"
echo "- commit: ${head_commit}"
echo "- version: ${version}"
echo "- tag: ${tag}"
echo
echo "Release notes preview:"
printf '%s\n' "${notes}" | sed -n '1,20p'
echo

read -r -p "Create and push ${tag}? [y/N] " confirm
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
  echo "Release cancelled."
  exit 0
fi

if [[ -z "${existing_tag_commit}" ]]; then
  git tag -a "${tag}" -m "Release ${tag}"
fi

echo "verifying ${tag}:"
git show --no-patch --decorate "${tag}"

echo "pushing main..."
git push origin main

echo "pushing ${tag}..."
git push origin "${tag}"

echo "release trigger sent: ${tag}"
