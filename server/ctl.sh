#!/usr/bin/env bash
# Control del servidor de desarrollo (servicio systemd de usuario).
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
L4D2_DIR="${L4D2_DIR:-$HOME/l4d2server}"
UNIT="l4d2-skilltree"
CONSOLE="$L4D2_DIR/console.in"

usage() {
    cat <<EOF
Uso: $(basename "$0") <comando>

  start            Prende el servidor
  stop             Apaga el servidor (guarda el progreso de los jugadores)
  restart          Reinicia el servidor
  status           Muestra si está corriendo
  logs             Sigue la consola del servidor (Ctrl+C para salir)
  cmd <comando>    Manda un comando a la consola (ej: cmd changelevel c2m1_highway)
  deploy           Compila, instala y recarga el plugin sin reiniciar
  install-service  Instala/actualiza el servicio systemd (una sola vez)
EOF
}

install_service() {
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/$UNIT.service" <<EOF
[Unit]
Description=L4D2 Skill Tree (servidor de desarrollo)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$L4D2_DIR
ExecStartPre=/bin/sh -c ': > "$CONSOLE"'
# script(1) da una terminal a srcds: la salida llega línea por línea al journal y lee comandos de console.in
ExecStart=/bin/sh -c 'tail -f "$CONSOLE" | script -qfec "$ROOT/server/start.sh" /dev/null'
# Apagado limpio con "quit" para que el plugin guarde a los jugadores
ExecStop=/bin/sh -c 'echo quit >> "$CONSOLE"; for i in \$(seq 15); do pgrep -u "\$USER" -x srcds_linux >/dev/null || exit 0; sleep 1; done'
TimeoutStopSec=20
# srcds_run sale con 130 al hacer "quit"
SuccessExitStatus=130

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    echo "Servicio $UNIT instalado."
}

case "${1:-}" in
    start|stop|restart|status)
        systemctl --user "$1" "$UNIT"
        ;;
    logs)
        journalctl --user -u "$UNIT" -f -n 50 -o cat
        ;;
    cmd)
        shift
        echo "$*" >> "$CONSOLE"
        ;;
    deploy)
        "$ROOT/build.sh"
        "$ROOT/server/install.sh"
        # El core primero: los demás módulos dependen de su API
        for smx in "$ROOT/plugins/l4d2_skilltree.smx" "$ROOT"/plugins/*.smx; do
            name="$(basename "$smx" .smx)"
            [[ "$name" == "l4d2_skilltree" && "$smx" != "$ROOT/plugins/l4d2_skilltree.smx" ]] && continue
            printf 'sm plugins unload %s\nsm plugins load %s\n' "$name" "$name" >> "$CONSOLE"
        done
        echo "Plugins recargados."
        ;;
    install-service)
        install_service
        ;;
    *)
        usage
        exit 1
        ;;
esac
