#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cp -R "$HERE/../_fixture/storefront/." .
git init -q -b main
git config user.email "eval@example.com"
git config user.name "Eval"
git add -A
git commit -q -m "fixture"
graphify update .
