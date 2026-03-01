#!/usr/bin/env bash
set -euo pipefail

VERSION=""
PKG_PATH=""
ZIP_PATH=""
NOTES="See CHANGELOG.md for details."
CHANGELOG_LINE=""
MIN_SUPPORTED_VERSION=""
DO_COMMIT=false
DO_PUSH=false

usage() {
  cat <<USAGE
Usage:
  $0 --version <x.y.z> --pkg <path> [options]

Required:
  --version <x.y.z>          Release version, for example 1.1.8
  --pkg <path>               Local .pkg artifact path

Optional:
  --zip <path>               Local .zip artifact path
  --min-supported <x.y.z>    minimumSupportedVersion for appcast (default: version)
  --notes <text>             releaseNotes for appcast and GitHub release
  --changelog <line>         one bullet line for CHANGELOG Added section
  --commit                   commit appcast/changelog changes
  --push                     push current branch and tags
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"; shift 2 ;;
    --pkg)
      PKG_PATH="$2"; shift 2 ;;
    --zip)
      ZIP_PATH="$2"; shift 2 ;;
    --min-supported)
      MIN_SUPPORTED_VERSION="$2"; shift 2 ;;
    --notes)
      NOTES="$2"; shift 2 ;;
    --changelog)
      CHANGELOG_LINE="$2"; shift 2 ;;
    --commit)
      DO_COMMIT=true; shift ;;
    --push)
      DO_PUSH=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "$VERSION" || -z "$PKG_PATH" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$PKG_PATH" ]]; then
  echo "Package not found: $PKG_PATH" >&2
  exit 1
fi

if [[ -n "$ZIP_PATH" && ! -f "$ZIP_PATH" ]]; then
  echo "Zip not found: $ZIP_PATH" >&2
  exit 1
fi

if [[ -z "$MIN_SUPPORTED_VERSION" ]]; then
  MIN_SUPPORTED_VERSION="$VERSION"
fi

TAG="v${VERSION}"

REMOTE_URL="$(git config --get remote.origin.url || true)"
if [[ -z "$REMOTE_URL" ]]; then
  echo "Cannot read remote.origin.url" >&2
  exit 1
fi

REPO_SLUG="$(echo "$REMOTE_URL" | sed -E 's#git@github.com:##; s#https://github.com/##; s#\.git$##')"
if [[ -z "$REPO_SLUG" ]]; then
  echo "Cannot parse repository from remote: $REMOTE_URL" >&2
  exit 1
fi

DOWNLOAD_URL="https://github.com/${REPO_SLUG}/releases/download/${TAG}/Voxt-${VERSION}.pkg"

scripts/release/generate_appcast.sh \
  "$VERSION" \
  "$PKG_PATH" \
  "$DOWNLOAD_URL" \
  "$MIN_SUPPORTED_VERSION" \
  "$NOTES" \
  "updates/appcast.json"

if [[ -z "$CHANGELOG_LINE" ]]; then
  CHANGELOG_LINE="- Release ${TAG}."
fi

if ! grep -q "^## \[${VERSION}\]" CHANGELOG.md; then
  TMP_FILE="$(mktemp)"
  TODAY="$(date +%Y-%m-%d)"
  awk -v ver="$VERSION" -v date="$TODAY" -v line="$CHANGELOG_LINE" '
    {
      print $0
      if (!inserted && $0 == "## [Unreleased]") {
        print ""
        print "## [" ver "] - " date
        print ""
        print "### Added"
        print line
        print ""
        inserted = 1
      }
    }
  ' CHANGELOG.md > "$TMP_FILE"
  mv "$TMP_FILE" CHANGELOG.md
fi

if $DO_COMMIT; then
  git add updates/appcast.json CHANGELOG.md
  if ! git diff --cached --quiet; then
    git commit -m "release: ${TAG}"
  fi
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag already exists: $TAG"
else
  git tag -a "$TAG" -m "Release ${TAG}"
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$PKG_PATH" ${ZIP_PATH:+"$ZIP_PATH"} --clobber
else
  if [[ -n "$ZIP_PATH" ]]; then
    gh release create "$TAG" "$PKG_PATH" "$ZIP_PATH" --title "$TAG" --notes "$NOTES"
  else
    gh release create "$TAG" "$PKG_PATH" --title "$TAG" --notes "$NOTES"
  fi
fi

if $DO_PUSH; then
  CURRENT_BRANCH="$(git branch --show-current)"
  git push origin "$CURRENT_BRANCH"
  git push origin "$TAG"
fi

echo "Release flow completed for ${TAG}"
