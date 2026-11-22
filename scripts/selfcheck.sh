#!/bin/zsh
set -euo pipefail

# One-shot self-check for the spm branch: builds the app, runs the headless
# audit scenarios (Sources/SkymapText/AppAudit.swift via --audit), then the
# repo's python gates. Swift tests need no Xcode; SwiftLint runs when installed.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

FAILED=0

echo "== swift build (debug) =="
swift build || FAILED=1

echo "== audit scenarios (--audit, headless) =="
.build/debug/SkyBook --audit || FAILED=1

if command -v swiftlint >/dev/null 2>&1; then
  echo "== swiftlint =="
  swiftlint lint --strict --quiet || FAILED=1
else
  echo "== swiftlint: not installed, skipped =="
fi

echo "== python gates =="
python3 scripts/check_incidents.py || FAILED=1
python3 -m unittest discover -s scripts -p 'test_*.py' || FAILED=1

if [[ $FAILED -eq 0 ]]; then
  echo "selfcheck: 全部通过"
else
  echo "selfcheck: 存在失败项"
fi
exit $FAILED
