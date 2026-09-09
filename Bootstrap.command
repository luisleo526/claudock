#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
if ! "$ROOT/scripts/bootstrap.sh"; then
    echo
    read -r -p "Setup did not finish. Press Return to close this window. " _reply
    exit 1
fi
