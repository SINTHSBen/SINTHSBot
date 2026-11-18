#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
export PATH="$DOTNET_ROOT:$PATH"
MODE="${1:-fd}" # fd | self
OUT="$ROOT/dist"
mkdir -p "$OUT"

if [[ "$MODE" == "self" ]]; then
  echo "Building self-contained win-x64 (large)..."
  dotnet publish "$ROOT/gui/HwidGui/HwidGui.csproj" \
    -c Release -r win-x64 --self-contained true \
    -p:PublishSingleFile=true \
    -p:EnableWindowsTargeting=true \
    -o "$OUT"
else
  echo "Building framework-dependent win-x64 (small; needs .NET 8 Desktop Runtime)..."
  dotnet publish "$ROOT/gui/HwidGui/HwidGui.csproj" \
    -c Release -r win-x64 --self-contained false \
    -p:PublishSingleFile=true \
    -p:EnableWindowsTargeting=true \
    -o "$OUT"
fi

ls -lh "$OUT/SINTHSBot-HWID.exe"
