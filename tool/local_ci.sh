#!/usr/bin/env bash
# The checks .github/workflows/ci.yml runs, on your own machine (CI on GitHub runs only on
# release tags, labeled pull requests or by hand, since Actions minutes cost money).
# Needs Flutter 3.38 (with its Dart) on PATH; Docker for "images"; Chrome or Chromium for "web"
# (set CHROME_EXECUTABLE if it isn't found).
# Usage, from the root of a Den checkout or worktree:
#   bash tool/local_ci.sh [targets...]
# Targets: a package name (den_core, den_hub, ...), "app", "web" (Chrome tests + sw test + CSP
# web build), "images" (docker builds of hub and relay), or "changed" (the default: whatever
# differs from the base branch, mapped the same way CI's paths filter maps it; the base is
# $DEN_CI_BASE, default main).
# Prints one PASS/FAIL line per step and keeps logs in .local-ci/ (git-ignored by
# .git/info/exclude). Exit code is non-zero if any step failed.
set -u
command -v flutter >/dev/null || { [ -x /opt/flutter/bin/flutter ] && export PATH=/opt/flutter/bin:$PATH; }
command -v flutter >/dev/null || { echo "Flutter isn't on PATH (https://docs.flutter.dev/get-started/install)"; exit 2; }
export PUB_ENVIRONMENT=local_ci
if [ -z "${CHROME_EXECUTABLE:-}" ]; then
  for c in google-chrome chromium chromium-browser; do command -v "$c" >/dev/null && { export CHROME_EXECUTABLE=$(command -v "$c"); break; }; done
fi
root=$(git rev-parse --show-toplevel) || exit 2
cd "$root"
logs="$root/.local-ci"; mkdir -p "$logs"
grep -qx '.local-ci/' "$(git rev-parse --git-common-dir)/info/exclude" 2>/dev/null ||
  echo '.local-ci/' >> "$(git rev-parse --git-common-dir)/info/exclude"
fail=0
step() { # name, dir, command...
  local name=$1 dir=$2; shift 2
  local log="$logs/${name//[^A-Za-z0-9_.-]/_}.log"
  if (cd "$dir" && "$@") > "$log" 2>&1; then echo "PASS  $name"; else
    echo "FAIL  $name  (log: $log)"; tail -n 40 "$log" | sed 's/^/      /'; fail=1; fi
}
pkgs_all="den_core den_net den_capture den_relay den_hub den_hub_cli den_sett_import den_assistant den_actions"
targets=("$@"); [ ${#targets[@]} -eq 0 ] && targets=(changed)
if [ "${targets[0]}" = changed ]; then
  base=${DEN_CI_BASE:-main}
  git fetch -q origin "$base:refs/remotes/origin/$base" 2>/dev/null
  files=$(git diff --name-only "origin/$base...HEAD"; git diff --name-only; git diff --name-only --cached)
  targets=()
  has() { echo "$files" | grep -qE "$1"; }
  for p in $pkgs_all; do
    case $p in
      den_core) re='^packages/den_core/';;
      den_net) re='^packages/den_(core|net)/';;
      den_capture) re='^packages/den_(core|capture)/';;
      den_relay) re='^packages/den_(core|net|relay)/';;
      den_sett_import) re='^packages/den_(core|sett_import)/';;
      den_assistant) re='^packages/den_assistant/';;  # depends on nothing else in the repo
      den_actions) re='^packages/den_(core|capture|assistant|actions)/';;
      den_hub|den_hub_cli) re='^(packages/|deploy/hub/)';;
    esac
    has "$re" && targets+=("$p")
  done
  has '^(packages/den_(core|net|capture|hub|relay|actions|assistant)/|app/)' && targets+=(app)
  has '^app/(web/|lib/platform/|test/web/)' && targets+=(web)
  has '^deploy/' && targets+=(images)
  [ ${#targets[@]} -eq 0 ] && { echo "Nothing to check against origin/$base."; exit 0; }
fi
echo "Checking: ${targets[*]}"
for t in "${targets[@]}"; do
  case $t in
    den_*)
      d=packages/$t
      step "$t pub get" "$d" dart pub get
      step "$t analyze" "$d" dart analyze --fatal-infos
      step "$t test" "$d" dart test
      [ "$t" = den_hub_cli ] && step "$t build cli" "$d" dart build cli
      ;;
    app)
      step "app pub get" app flutter pub get
      step "app analyze" app flutter analyze
      step "app test" app flutter test --exclude-tags golden
      ;;
    web)
      step "web sw test" app node test/web/sw_test.mjs web/sw.js
      if [ -n "${CHROME_EXECUTABLE:-}" ]; then
        step "web chrome tests" app flutter test --platform chrome test/web
      else echo "SKIP  web chrome tests (no Chrome; set CHROME_EXECUTABLE)"; fi
      step "web build (csp)" app flutter build web --release --csp --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/
      ;;
    images)
      step "image hub" . docker build -q -f deploy/hub/Dockerfile .
      step "image relay" . docker build -q -f deploy/relay/Dockerfile .
      ;;
    *) echo "Unknown target $t"; fail=1;;
  esac
done
# Lockfiles that only changed because of a local pub get are not part of the change.
exit $fail
