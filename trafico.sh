#!/usr/bin/env bash
# trafico.sh — Provoca escenarios de tráfico y te dice QUÉ mirar en el dashboard.
#
# Uso:
#   ./trafico.sh pico      # ráfaga de checkouts  -> pico en "Errors — 5xx/s por ruta"
#   ./trafico.sh lento     # pico forzado en /slow -> el p95 de "Duration" x5 (el p99 NO)
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

hit() { # hit <ruta> <n> [paralelo] -> lanza n peticiones y cuenta cuántas dieron 200
  #
  # DOS TRAMPAS QUE YA COSTARON UN BUG (no las "simplifiques"):
  #
  # 1) `xargs -P` en vez de subshells con `&`. En Git Bash (Windows), un curl con
  #    `-o /dev/null` dentro de `{ ...; } &` —o dentro de `$( ... | tr ... )`— acaba en
  #        curl: (23) client returned ERROR on write of 42 bytes
  #    aunque el HTTP haya devuelto 200: falla al escribir el CUERPO de la respuesta.
  #    Resultado: la ráfaga funcionaba de verdad, pero el script reportaba
  #    "0 ok · 30 con error" y parecía que todo estaba roto.
  #
  # 2) El `|| true` del final es obligatorio. Con `set -o pipefail`, si UNA sola
  #    petición falla xargs sale con 123, el pipeline se considera fallido y `set -e`
  #    mataría el script justo después del banner, sin imprimir nada.
  #
  # El paralelismo además hace la demo usable en vivo: 30 peticiones a /slow (1-2.5 s
  # cada una) serían ~50 s en serie; de 6 en 6 son ~10 s.
  local ruta="$1" n="$2" par="${3:-6}" codigos ok
  codigos="$(seq 1 "$n" | xargs -P "$par" -I{} \
      curl -s -o /dev/null -w '%{http_code}\n' "${APP_URL}${ruta}" 2>/dev/null | tr -d '\r' || true)"
  ok="$(printf '%s\n' "$codigos" | grep -c '^200$' || true)"
  printf '   %-18s -> %2d peticiones · %2d ok · %2d con error\n' \
    "$ruta" "$n" "$ok" "$(( n - ok ))"
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
    banner "PICO DE LATENCIA — ráfaga a /slow con pico FORZADO (app: ${APP_URL})"
    # ?spike=1 fuerza el pico en cada petición. Sin forzarlo, la ráfaga metería un 90%
    # de peticiones rápidas y DILUIRÍA la cola: el p95 casi no se movía (ver el docstring
    # de /slow en app/main.py). Forzado, el salto del p95 es del 100% de las veces.
    hit "/slow?spike=1" 30 6
    cat <<'EOF'

 👀 QUÉ MIRAR EN EL DASHBOARD (dale ~30 s):
    · "Duration — p95 (todas las rutas)"  -> de ~0.4 s (verde) a ~2 s (rojo)
    · "Duration — latencia p50 / p95 / p99 (con exemplars)":
        - el p95 (NARANJA) se dispara: ~0.4 s -> ~2 s
        - el p99 (AZUL) se queda donde estaba, ~3 s. NO es un fallo del panel:
          /slow tarda como MÁXIMO 2.5 s, y el p99 lo fijan los timeouts de
          /checkout (2.8-3.5 s), que son más lentos. Cada percentil tiene su dueño:
          el p50 es "/", el p95 es /slow, el p99 es /checkout.
          Para mover el p99 usa "./trafico.sh pico" o "./ajustar.sh fallo 50".
    · Diamantes nuevos en la banda 1-2.5 s = estas peticiones -> clic -> su traza
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
