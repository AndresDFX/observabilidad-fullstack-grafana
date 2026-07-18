#!/usr/bin/env bash
# trafico.sh — Provoca escenarios de tráfico y te dice QUÉ mirar en el dashboard.
#
# Uso:
#   ./trafico.sh pico      # ráfaga de checkouts  -> pico en "Errors — 5xx/s por ruta"
#   ./trafico.sh lento     # ráfaga a /slow       -> sube el p95/p99 en "Duration"
#   ./trafico.sh mixto     # un poco de todo (por defecto)
#
# El loadgen ya genera tráfico de fondo; esto añade una RÁFAGA puntual para que
# el efecto se vea claro en los paneles (~30 s después, por el intervalo de export).
set -euo pipefail

ESCENARIO="${1:-mixto}"

# Descubre dónde quedó publicada la app (soporta mapeos de puerto alternativos).
PORT_MAP="$(docker compose port app 8000 2>/dev/null || true)"
APP_URL="http://localhost:${PORT_MAP##*:}"
[ -z "${PORT_MAP}" ] && APP_URL="http://localhost:8000"

hit() { # hit <ruta> <n>  -> lanza n peticiones y cuenta códigos de respuesta
  local ruta="$1" n="$2" ok=0 err=0 code
  for _ in $(seq 1 "$n"); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "${APP_URL}${ruta}" || echo 000)
    if [ "$code" = "200" ]; then ok=$((ok+1)); else err=$((err+1)); fi
  done
  printf '   %-10s -> %2d peticiones · %2d ok · %2d con error\n' "$ruta" "$n" "$ok" "$err"
}

banner() {
  echo "════════════════════════════════════════════════════════════"
  echo " ESCENARIO: $1"
  echo "════════════════════════════════════════════════════════════"
}

case "$ESCENARIO" in
  pico)
    banner "PICO DE ERRORES — ráfaga de checkouts (app: ${APP_URL})"
    hit /checkout 60
    cat <<'EOF'

 👀 QUÉ MIRAR EN EL DASHBOARD (dale ~30 s):
    · "Errors — % de 5xx"        -> el número sube
    · "Errors — 5xx/s por ruta"  -> pico rojo en /checkout
    · "Duration — latencia p50 / p95 / p99 (con exemplars)" -> nuevos diamantes para el drill-down
EOF
    ;;
  lento)
    banner "PICO DE LATENCIA — ráfaga a /slow (app: ${APP_URL})"
    hit /slow 40
    cat <<'EOF'

 👀 QUÉ MIRAR EN EL DASHBOARD (dale ~30 s):
    · "Duration — p95 (todas las rutas)"      -> sube
    · "Duration — latencia p50 / p95 / p99 (con exemplars)" -> el p99 (azul) se dispara;
      los diamantes de la zona ALTA son las peticiones lentas -> clic para ver su traza
EOF
    ;;
  mixto)
    banner "TRÁFICO MIXTO — de todo un poco (app: ${APP_URL})"
    hit / 30
    hit /slow 15
    hit /checkout 25
    cat <<'EOF'

 👀 QUÉ MIRAR EN EL DASHBOARD (dale ~30 s):
    · "Rate — peticiones/s por ruta" -> suben las tres rutas
    · "Errors" y "Duration"          -> errores de /checkout y cola de /slow
EOF
    ;;
  *)
    echo "Uso: ./trafico.sh [pico|lento|mixto]" >&2
    exit 1
    ;;
esac
