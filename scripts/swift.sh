#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
python3 scripts/prepare-toolchain.py
python3 scripts/embed-guide.py
source .build/toolchain.env
if [[ -n "$FIELDWORK_SWIFT_LIBS" ]]; then
    export SWIFTPM_CUSTOM_LIBS_DIR="$FIELDWORK_SWIFT_LIBS"
fi
extra=()
if [[ -n "$FIELDWORK_SWIFT_OVERLAY" ]]; then
    extra=(-Xswiftc -vfsoverlay -Xswiftc "$FIELDWORK_SWIFT_OVERLAY" -Xswiftc -module-cache-path -Xswiftc "$project_root/.build/fieldwork-module-cache")
fi
exec swift "$@" "${extra[@]}"
