#!/usr/bin/env bash
# publish_fork_release.sh - publish this checkout as a release of your fork, which installed copies
# then update to through "Check for Updates".
#
# How updates reach people: the shared app is the Dev variant built with an update feed of its own,
#   https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
# GitHub serves that from the newest release, so every release carries the DMG and an appcast that
# describes it. Sparkle in the app reads the appcast, checks the DMG's EdDSA signature against the
# public key built into the app, and installs it. The official feed is never used (AppUpdateManager).
#
# Steps:
#   1. Sparkle's tools, at the version the app links (Package.resolved), checked against the
#      SHA-256 the release workflow pins, cached in ~/Library/Caches/Cotabby.
#   2. The signing key: created once with generate_keys and kept in your login keychain under the
#      account "cotabby-fork" (never the official key). Back it up: without it, installed copies
#      cannot accept another update (`generate_keys --account cotabby-fork -x <file>` exports it).
#   3. The DMG, through build_share_dmg.sh, with the feed, the public key, version
#      "<last tag>-s<commit count>" and build number <commit count> (what Sparkle compares).
#   4. The update signature and appcast.xml.
#   5. After you confirm: a GitHub release on the fork, tagged at this commit, marked latest.
#
# The commit must already be on GitHub (push the branch first); the script does not push.
# Usage: bash scripts/publish_fork_release.sh [--yes]
#   COTABBY_RELEASE_REPO   owner/repo (default: the "fork" remote)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
KEY_ACCOUNT="cotabby-fork"
CACHE_DIR="$HOME/Library/Caches/Cotabby"
OUT_DIR="$REPO_ROOT/build/share"
assume_yes=false
[[ "${1:-}" == "--yes" ]] && assume_yes=true

note() { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

command -v gh >/dev/null || fail "the GitHub CLI (gh) is required"
repo="${COTABBY_RELEASE_REPO:-$(git remote get-url fork 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "cannot tell the fork's owner/repo; set COTABBY_RELEASE_REPO"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "commit or stash your changes first: a release is built from a commit"
commit="$(git rev-parse HEAD)"
git fetch --quiet fork 2>/dev/null || true
[[ -n "$(git branch -r --contains "$commit" 2>/dev/null | grep -E '^\s*fork/')" ]] \
    || fail "commit ${commit:0:8} is not on GitHub yet; push it to the fork first (git push fork HEAD)"

step "Sparkle tools"
sparkle_version="$(python3 -c "import json; print([p for p in json.load(open('Config/Package.resolved'))['pins'] if p['identity'] == 'sparkle'][0]['state']['version'])")"
sparkle_sha="$(sed -n 's/^ *SPARKLE_SHA256: *//p' .github/workflows/release.yml | head -1)"
sparkle_dir="$CACHE_DIR/sparkle-$sparkle_version"
if [[ ! -x "$sparkle_dir/bin/sign_update" ]]; then
    mkdir -p "$sparkle_dir"
    curl -fsSL -o "$sparkle_dir/Sparkle.tar.xz" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
    echo "$sparkle_sha  $sparkle_dir/Sparkle.tar.xz" | shasum -a 256 --check --quiet \
        || { rm -rf "$sparkle_dir"; fail "Sparkle $sparkle_version download does not match the pinned checksum"; }
    tar -xJf "$sparkle_dir/Sparkle.tar.xz" -C "$sparkle_dir"
fi
note "Sparkle $sparkle_version"

step "Update signing key"
# An Ed25519 public key is 32 bytes, 44 characters of base64. generate_keys prints its "no key"
# error on standard output, so the output is checked for that shape rather than for being non-empty.
is_key() { [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
public_key="$("$sparkle_dir/bin/generate_keys" --account "$KEY_ACCOUNT" -p 2>/dev/null || true)"
if ! is_key "$public_key"; then
    note "creating the fork's signing key (stored in your login keychain)"
    "$sparkle_dir/bin/generate_keys" --account "$KEY_ACCOUNT" >/dev/null
    public_key="$("$sparkle_dir/bin/generate_keys" --account "$KEY_ACCOUNT" -p)"
    is_key "$public_key" || fail "generate_keys did not produce a public key"
    note "back it up: $sparkle_dir/bin/generate_keys --account $KEY_ACCOUNT -x <file>"
fi
note "public key: $public_key"

base="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-s[0-9]*' 2>/dev/null | sed 's/^v//')"
build="$(git rev-list --count HEAD)"
version="${base:-0.0.0}-s$build"
tag="v$version"
dmg_name="Cotabby-Dev-$version.dmg"
dmg="$OUT_DIR/$dmg_name"
feed="https://github.com/$repo/releases/latest/download/appcast.xml"
gh release view "$tag" --repo "$repo" >/dev/null 2>&1 && fail "release $tag already exists on $repo"

step "Building $version"
COTABBY_SHARE_VERSION="$version" COTABBY_SHARE_BUILD="$build" COTABBY_SHARE_DMG="$dmg" \
    COTABBY_SHARE_PROJECT_URL="https://github.com/$repo" \
    COTABBY_SHARE_FEED_URL="$feed" COTABBY_SHARE_PUBLIC_KEY="$public_key" \
    bash "$REPO_ROOT/scripts/build_share_dmg.sh"

step "Signing the update"
signature="$("$sparkle_dir/bin/sign_update" --account "$KEY_ACCOUNT" "$dmg")"
[[ "$signature" == *'sparkle:edSignature="'* ]] || fail "sign_update gave no signature"
appcast="$OUT_DIR/appcast.xml"
cat >| "$appcast" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cotabby Dev ($repo)</title>
    <link>https://github.com/$repo/releases</link>
    <item>
      <title>$version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/$repo/releases/tag/$tag</link>
      <enclosure url="https://github.com/$repo/releases/download/$tag/$dmg_name" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
XML
note "appcast: $appcast"

step "Ready to publish"
note "repository: $repo (public: anyone can download this release)"
note "release:    $tag at ${commit:0:8} ($(git rev-parse --abbrev-ref HEAD))"
note "files:      $dmg_name, appcast.xml"
if ! $assume_yes; then
    read -r -p "  Publish now? [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || { note "not published; the DMG and appcast stay in build/share"; exit 0; }
fi
notes="Cotabby Dev $version, built from ${commit:0:8}. Installed copies update to it from Check for Updates."
gh release create "$tag" "$dmg" "$appcast" --repo "$repo" --target "$commit" --title "Cotabby Dev $version" \
    --notes "$notes" --latest
step "Published: https://github.com/$repo/releases/tag/$tag"
