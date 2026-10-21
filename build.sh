#!/usr/bin/env bash
# Compila los plugins de scripting/ a plugins/*.smx.
# La primera vez descarga SourceMod (solo para usar spcomp y los includes) en .sourcemod/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# Usar la misma versión de SourceMod en el servidor
SM_TAG="${SM_TAG:-1.12.0.7255}"
SM_DIR="$ROOT/.sourcemod"
SCRIPTING="$SM_DIR/addons/sourcemod/scripting"

if [[ ! -d "$SCRIPTING/include" ]]; then
    echo "Descargando SourceMod $SM_TAG..."
    IFS=. read -r major minor patch build <<< "$SM_TAG"
    mkdir -p "$SM_DIR"
    curl -fsSL "https://github.com/alliedmodders/sourcemod/releases/download/$SM_TAG/sourcemod-$major.$minor.$patch-git$build-linux.tar.gz" \
        | tar -xz -C "$SM_DIR"
fi

SPCOMP="$SCRIPTING/spcomp64"
[[ -x "$SPCOMP" ]] || SPCOMP="$SCRIPTING/spcomp"

mkdir -p "$ROOT/plugins"
for src in "$ROOT"/scripting/*.sp; do
    name="$(basename "${src%.sp}")"
    "$SPCOMP" "$src" -i"$SCRIPTING/include" -i"$ROOT/scripting/include" -o"$ROOT/plugins/$name.smx"
done
