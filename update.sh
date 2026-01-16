#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
powershell -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/update.ps1" $*