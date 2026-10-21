#!/usr/bin/env bash
# Instala Metamod:Source + SourceMod en el servidor dedicado (solo la primera vez),
# configura el admin y copia el plugin compilado. Re-ejecutar tras cada ./build.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L4D2_DIR="${L4D2_DIR:-$HOME/l4d2server}"
GAME="$L4D2_DIR/left4dead2"
MM_TAG="${MM_TAG:-1.12.0.1228}"
SM_TAG="${SM_TAG:-1.12.0.7255}"
ADMIN_STEAMID="${ADMIN_STEAMID:-STEAM_1:0:102114831}"

release_url() { # repo tag prefijo
    local major minor patch build
    IFS=. read -r major minor patch build <<< "$2"
    echo "https://github.com/alliedmodders/$1/releases/download/$2/$3-$major.$minor.$patch-git$build-linux.tar.gz"
}

if [[ ! -f "$GAME/addons/metamod.vdf" ]]; then
    echo "Instalando Metamod:Source $MM_TAG..."
    curl -fsSL "$(release_url metamod-source "$MM_TAG" mmsource)" | tar -xz -C "$GAME"
    rm -f "$GAME/addons/metamod_x64.vdf"  # L4D2 es de 32 bits
fi

if [[ ! -d "$GAME/addons/sourcemod" ]]; then
    echo "Instalando SourceMod $SM_TAG..."
    curl -fsSL "$(release_url sourcemod "$SM_TAG" sourcemod)" | tar -xz -C "$GAME"
    mv "$GAME/addons/sourcemod/plugins/nextmap.smx" "$GAME/addons/sourcemod/plugins/disabled/"  # no es compatible con L4D2
fi

ADMINS="$GAME/addons/sourcemod/configs/admins_simple.ini"
if ! grep -q "$ADMIN_STEAMID" "$ADMINS"; then
    echo "\"$ADMIN_STEAMID\" \"99:z\"" >> "$ADMINS"
fi

if [[ ! -f "$GAME/cfg/server.cfg" ]]; then
    cp "$ROOT/server/server.cfg" "$GAME/cfg/server.cfg"
fi

cp "$ROOT"/plugins/*.smx "$GAME/addons/sourcemod/plugins/"
echo "Listo: plugins copiados a $GAME/addons/sourcemod/plugins/"
