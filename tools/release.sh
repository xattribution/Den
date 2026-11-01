#!/usr/bin/env bash
# Publishes a Den release from this checkout, on your own machine (x86_64 Linux with Docker; no
# GitHub Actions): one image, ghcr.io/xattribution/den, for linux/amd64 and linux/arm64, tagged
# vX.Y.Z and (unless it's a pre-release) stable, which every server installed with
# deploy/install.sh moves to on its next nightly update. docs/install-technical.md, "Releasing".
#
#   tools/release.sh v1.2.0                  build, push vX.Y.Z and stable
#   tools/release.sh v1.2.0-rc.1             a pre-release: pushes only its own tag
#   tools/release.sh v1.2.0 --no-stable      push vX.Y.Z only (try it on one server first with
#                                            sudo den --image ghcr.io/xattribution/den:v1.2.0)
#   tools/release.sh v1.2.0 --dry-run        say what it would do
#   tools/release.sh --promote v1.2.0        point stable at an already-pushed release
#
# Other options: --allow-dirty (build uncommitted changes), --publish-script (upload
# deploy/install.sh to the public script repository's release, with gh).
#
# The web app compiles once, on this machine (it's the same for both platforms); the hub
# compiles once per platform, the ARM one under QEMU emulation, since `dart build cli` (which the
# hub needs for sqlite3's build hook) can't cross-compile yet. That takes about 15-25 minutes.
# To make it faster, add a real ARM machine to the builder:
#   docker buildx create --append --name den-release --platform linux/arm64 ssh://you@your-pi
set -euo pipefail

IMAGE=ghcr.io/xattribution/den
PLATFORMS=linux/amd64,linux/arm64
BUILDER=den-release
BINFMT=tonistiigi/binfmt:qemu-v10.2.3
SCRIPT_REPO=xattribution/den-install   # public: serves install.sh (docs/install-technical.md)

version='' stable=1 dry=0 dirty=0 promote=0 publish_script=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-stable) stable=0 ;;
    --dry-run) dry=1 ;;
    --allow-dirty) dirty=1 ;;
    --promote) promote=1 ;;
    --publish-script) publish_script=1 ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    v*) version=$1 ;;
    *) echo "release.sh: unknown argument $1 (see --help)" >&2; exit 64 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
stop() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$dry" = 1 ]; then say "   would run: $*"; else say "   \$ $*"; "$@"; fi
}

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] ||
  stop "name the release as vMAJOR.MINOR.PATCH, like v1.2.0 (or v1.2.0-rc.1 for a pre-release)."
case "$version" in *-*) stable=0 ;; esac

cd "$(dirname "$0")/.."

step "Docker"
command -v docker > /dev/null || stop "this needs Docker (docs.docker.com/engine/install)."
docker buildx version > /dev/null 2>&1 || stop "this needs Docker's buildx plugin (docker-buildx-plugin)."
docker info > /dev/null 2>&1 || stop "Docker isn't running, or this user can't use it (sudo usermod -aG docker \$USER, then log in again)."
[ "$(uname -m)" = x86_64 ] || say "   (not x86_64: the build still works, with the other platform emulated)"

# Signed in to ghcr.io? The credential helper or config.json knows.
logged_in() {
  local config=${DOCKER_CONFIG:-$HOME/.docker}/config.json
  [ -f "$config" ] && grep -q '"ghcr.io"' "$config"
}
if ! logged_in; then
  cat <<'EOF'

   Not signed in to ghcr.io yet. Once, on this machine:

   1. Make a token: github.com/settings/tokens/new?scopes=write:packages
      (a classic token; "write:packages" includes read). Give it a long expiry, copy it.
   2. Sign in with it:
        echo <the token> | docker login ghcr.io -u <your GitHub user name> --password-stdin
   3. Run this again. After the first push, make the package public (the step at the end
      says how), so servers download it without signing in.
EOF
  [ "$dry" = 1 ] || exit 1
fi

if [ "$promote" = 1 ]; then
  step "Pointing stable at $version"
  run docker buildx imagetools create -t "$IMAGE:stable" "$IMAGE:$version"
  say "   Servers move to $version on their next nightly update (or now: sudo den update)."
  exit 0
fi

step "The checkout"
commit=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain)" ]; then
  [ "$dirty" = 1 ] || stop "there are uncommitted changes (git status). Commit them, or build them anyway with --allow-dirty."
  commit="$commit-dirty"
fi
say "   $version from $commit ($(git rev-parse --abbrev-ref HEAD))"

step "The builder"
if ! docker buildx inspect "$BUILDER" > /dev/null 2>&1; then
  run docker buildx create --name "$BUILDER" --driver docker-container --bootstrap
fi
if ! docker buildx inspect "$BUILDER" --bootstrap 2>/dev/null | grep -q 'linux/arm64'; then
  say "   ARM isn't emulated here yet: installing QEMU's handlers (once per boot of this machine)."
  run docker run --privileged --rm "$BINFMT" --install arm64
  run docker buildx inspect "$BUILDER" --bootstrap > /dev/null
fi

also=; [ "$stable" = 1 ] && also=" and stable"
step "Build and push $IMAGE:$version$also"
tags=(-t "$IMAGE:$version")
[ "$stable" = 1 ] && tags+=(-t "$IMAGE:stable")
run docker buildx build --builder "$BUILDER" --platform "$PLATFORMS" \
  -f deploy/hub/Dockerfile \
  --build-arg DEN_COMMIT="$commit" --build-arg DEN_VERSION="$version" \
  --label org.opencontainers.image.revision="$commit" \
  --provenance=false \
  "${tags[@]}" --push .

step "Check"
if [ "$dry" = 0 ]; then
  docker buildx imagetools inspect "$IMAGE:$version" | sed -n '/Platform:/s/^ */   /p'
fi

# Can a server download it without signing in? (The package must be public.)
anon_token=$(curl -fsS "https://ghcr.io/token?scope=repository:${IMAGE#ghcr.io/}:pull" 2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true)
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${anon_token:-none}" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' "https://ghcr.io/v2/${IMAGE#ghcr.io/}/manifests/$version" || true)
if [ "$code" = 200 ]; then
  say "   Public: servers can download it without signing in."
else
  cat <<EOF
   Servers can't download it yet without signing in (ghcr.io answered $code). Once:
   github.com/orgs/xattribution/packages/container/den/settings, "Danger Zone",
   Change visibility, Public. (If GitHub doesn't offer it: the organization's Settings,
   Packages, allow public packages.) Nothing secret is in the image: the family's data and
   keys live on each server, never in it.
EOF
fi

step "Mark the commit"
# Not a v* tag: pushing one starts the paid GitHub Actions release (.github/workflows/ci.yml).
if git rev-parse -q --verify "refs/tags/release/$version" > /dev/null; then
  say "   release/$version is already tagged"
else
  run git tag -a "release/$version" -m "Den $version (image $IMAGE:$version)"
fi
say "   To share the tag: git push origin release/$version"

step "The install script"
if [ "$publish_script" = 1 ]; then
  command -v gh > /dev/null || stop "--publish-script needs the GitHub CLI (gh), signed in."
  run gh release create "$version" deploy/install.sh --repo "$SCRIPT_REPO" --title "Den $version" \
    --notes "deploy/install.sh at $commit. Install: curl -fsSL https://get.kotvas.app | sudo sh"
else
  say "   deploy/install.sh changes only with a release; to publish it where get.kotvas.app points:"
  say "     tools/release.sh $version --publish-script   (or: gh release create $version deploy/install.sh --repo $SCRIPT_REPO)"
fi

say ""
if [ "$stable" = 1 ]; then
  say "Done: servers move to $version on their next nightly update (or now: sudo den update)."
else
  say "Done: $version is pushed but not stable. Try it: sudo den --image $IMAGE:$version ;"
  say "then: tools/release.sh --promote $version"
fi
