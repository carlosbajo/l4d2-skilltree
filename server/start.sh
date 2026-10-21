#!/usr/bin/env bash
# Arranca el servidor dedicado. Mapa por defecto: Dead Center, capítulo 1.
set -euo pipefail

L4D2_DIR="${L4D2_DIR:-$HOME/l4d2server}"
MAP="${1:-c1m1_hotel}"
# El cliente de L4D2 abierto en esta máquina ocupa el 27015
PORT="${PORT:-27016}"

cd "$L4D2_DIR"
exec ./srcds_run -game left4dead2 -console -port "$PORT" +exec server.cfg +map "$MAP"
