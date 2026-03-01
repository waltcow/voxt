---
name: voxt-release
description: Local release workflow for Voxt. Use this after building a local .pkg/.zip with Xcode Archive. Updates appcast and changelog, then creates git tag and GitHub release.
---

# Voxt Local Release Skill

## When to use
- You already built release artifacts locally (at least `Voxt-<version>.pkg`).
- You want to update `updates/appcast.json`, update `CHANGELOG.md`, create `git tag`, and publish a GitHub release.

## Prerequisites
- `gh` CLI is installed and authenticated.
- `origin` points to the target GitHub repository.
- Local build artifact exists, for example:
  - `build/release/Voxt-1.1.8.pkg`
  - optional: `build/release/Voxt-1.1.8-macOS.zip`

## One-command flow
Run:

```bash
scripts/release/publish_local_release.sh \
  --version 1.1.8 \
  --pkg build/release/Voxt-1.1.8.pkg \
  --zip build/release/Voxt-1.1.8-macOS.zip \
  --notes "See CHANGELOG.md for details." \
  --changelog "- Your release highlight here." \
  --commit --push
```

## What the script does
1. Computes package sha256.
2. Updates `updates/appcast.json` with:
   - `version`
   - `minimumSupportedVersion`
   - `downloadURL`
   - `releaseNotes`
   - `publishedAt`
   - `sha256`
3. Inserts a new version section into `CHANGELOG.md` right after `## [Unreleased]`.
4. Optionally commits changes.
5. Creates annotated git tag `v<version>`.
6. Creates GitHub release and uploads `.pkg` (and optional `.zip`).
7. Optionally pushes commit and tags.

## Notes
- Keep version numeric (for in-app update comparison), e.g. `1.1.8`.
- Avoid suffix versions like `1.1.8-rc1` because the app compares dot-separated numeric parts.
