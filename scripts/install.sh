#!/bin/bash
# Builds and installs /Applications/Bassment.app, restarting it if it is running.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle.sh
pkill -x Bassment || true
sleep 1
mkdir -p /Applications/Bassment.app
rsync -a --delete build/Bassment.app/ /Applications/Bassment.app/
open /Applications/Bassment.app
