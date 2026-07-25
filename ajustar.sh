#!/usr/bin/env bash
# ajustar.sh — Gira las "perillas" del sistema EN VIVO y mira el dashboard reaccionar.
#
# Este es el corazón del formato del taller: no editas código ni YAML; ajustas un
# parámetro con un script y observas el efecto en Grafana. Causa -> efecto, visual.
#
# Uso:
#   ./ajustar.sh fallo 50      # el 50% de los checkouts fallan  (INCIDENTE GRAVE)
#   ./ajustar.sh fallo 0       # nadie falla                    ("desplegaste el fix")
#   ./ajustar.sh latencia 60   # el 60% de /slow tiene picos de 1-2.5 s
#   ./ajustar.sh reset         # vuelve a los valores del taller (fallo 20, latencia 10)
#   ./ajustar.sh estado        # muestra las perillas actuales
#
# Cómo funciona: escribe la perilla en `.env` (Compose lo lee automáticamente) y
# recrea SOLO el contenedor de la app (~2 s). La telemetría no se pierde: vive en lgtm.
set -euo pipefail

ENV_FILE=".env"
PERILLA="${1:-estado}"
VALOR="${2:-}"

set_var() { # set_var NOMBRE VALOR -> upsert en .env
  local nombre="$1" valor="$2"
  touch "$ENV_FILE"
  if grep -q "^${nombre}=" "$ENV_FILE" 2>/dev/null; then
    # sed -i portable (GNU y BSD) vía archivo temporal
    sed "s/^${nombre}=.*/${nombre}=${valor}/" "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
  else
    echo "${nombre}=${valor}" >> "$ENV_FILE"
  fi
}

get_var() { grep "^${1}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true; }

validar_pct() {
  case "$1" in (''|*[!0-9]*) echo "El valor debe ser un número 0-100" >&2; exit 1;; esac
  [ "$1" -ge 0 ] && [ "$1" -le 100 ] || { echo "El valor debe estar entre 0 y 100" >&2; exit 1; }
}

aplicar() {
  echo
  echo "==> Recreando solo el contenedor de la app con la nueva perilla (~2 s)..."
  docker compose up -d app >/dev/null 2>&1
  echo "==> Listo. Perillas activas:"
  docker compose exec -T app sh -c 'echo "    CHECKOUT_FAILURE_RATE=${CHECKOUT_FAILURE_RATE}%  SLOW_SPIKE_RATE=${SLOW_SPIKE_RATE}%"'
}

case "$PERILLA" in
  fallo)
    validar_pct "$VALOR"
    echo "════════════════════════════════════════════════════════════"
    echo " PERILLA: tasa de fallo de /checkout -> ${VALOR}%"
    echo "════════════════════════════════════════════════════════════"
    set_var CHECKOUT_FAILURE_RATE "$VALOR"
    aplicar
    cat <<EOF

 👀 QUÉ MIRAR EN EL DASHBOARD (~30-60 s):
    · "Errors — % de 5xx"        -> se moverá hacia ~${VALOR}% del tráfico de /checkout
    · "Errors — 5xx/s por ruta"  -> la línea roja de /checkout cambia de nivel
    Si pusiste 0: acabas de "desplegar el fix" — mira la recuperación en vivo. 📉
EOF
    ;;
  latencia)
    validar_pct "$VALOR"
    echo "════════════════════════════════════════════════════════════"
    echo " PERILLA: % de picos de latencia en /slow -> ${VALOR}%"
    echo "════════════════════════════════════════════════════════════"
    set_var SLOW_SPIKE_RATE "$VALOR"
    aplicar
    cat <<'EOF'

 👀 QUÉ MIRAR EN EL DASHBOARD (~30-60 s):
    · "Duration — p95 (todas las rutas)" y "Duration — latencia p50 / p95 / p99 (con exemplars)"
      -> el p95 (NARANJA) cambia de nivel. El p99 apenas se mueve: esta perilla toca /slow,
         y el p99 lo gobiernan los timeouts de /checkout (usa la perilla "fallo" para eso).
    · Los diamantes (exemplars) de la zona alta te llevan a las trazas lentas
EOF
    ;;
  reset)
    echo "==> Volviendo a los valores del taller (fallo 20%, latencia 10%)..."
    set_var CHECKOUT_FAILURE_RATE 20
    set_var SLOW_SPIKE_RATE 10
    aplicar
    ;;
  estado)
    echo "Perillas configuradas (${ENV_FILE}):"
    echo "  CHECKOUT_FAILURE_RATE=$(get_var CHECKOUT_FAILURE_RATE)  (vacío = 20 por defecto)"
    echo "  SLOW_SPIKE_RATE=$(get_var SLOW_SPIKE_RATE)  (vacío = 10 por defecto)"
    echo
    echo "Perillas ACTIVAS en el contenedor:"
    docker compose exec -T app sh -c 'echo "  CHECKOUT_FAILURE_RATE=${CHECKOUT_FAILURE_RATE}%  SLOW_SPIKE_RATE=${SLOW_SPIKE_RATE}%"' 2>/dev/null \
      || echo "  (la app no está corriendo — ./start.sh primero)"
    ;;
  *)
    echo "Uso: ./ajustar.sh [fallo <0-100> | latencia <0-100> | reset | estado]" >&2
    exit 1
    ;;
esac
