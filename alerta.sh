#!/usr/bin/env bash
# alerta.sh — ¿En qué estado está la ALERTA del taller? ¿Llegaron notificaciones?
#
# ¿A DÓNDE LLEGAN LAS ALERTAS? (la duda #1 del taller)
#   1. Grafana evalúa la regla cada 30 s: "¿más del 40% de /checkout está fallando?".
#   2. Si se cumple y se SOSTIENE 1 minuto (`for: 1m`), la regla pasa a FIRING.
#   3. Al disparar, Grafana envía la notificación al "contact point" del taller,
#      que es un WEBHOOK apuntando a la PROPIA app: POST http://app:8000/alerta.
#      (No hay correo ni Slack: todo es local, sin credenciales externas.)
#   4. La app recibe ese POST y escribe un log: "🔔 ALERTA FIRING: ...".
#   5. Ese log viaja por OTLP a LOKI. Por eso este script las lee DESDE LOKI:
#      los logs del contenedor se pierden al girar perillas, Loki es la memoria durable.
#   En producción solo cambias el contact point por Slack/PagerDuty; la regla no se toca.
#
# Uso:
#   ./alerta.sh            # estado de la regla + últimas notificaciones (desde Loki)
#   ./alerta.sh probar     # receta para dispararla y resolverla con las perillas
#
# OJO: este script NO usa `set -e` a propósito. Es una herramienta de diagnóstico:
# si una consulta falla, queremos VER el motivo, no que el script muera callado.
set -uo pipefail

# ---------------------------------------------------------------------------
# Parser de JSON: `jq` (GitHub Codespaces / Linux) o `python` (Git Bash en Windows).
#
# HISTORIA DE UN BUG: antes esto era una sola línea,
#     PY="$(command -v python3 || command -v python)"
# con `set -euo pipefail` activo. La imagen del devcontainer de Codespaces
# (mcr.microsoft.com/devcontainers/base:ubuntu) NO trae python ni python3, así que
# `command -v` devolvía error, `set -e` mataba el script y ./alerta.sh no imprimía
# ABSOLUTAMENTE NADA. Ahora detectamos varias opciones y, si no hay ninguna,
# avisamos claro en vez de morir en silencio.
# ---------------------------------------------------------------------------
JSON_MODE="ninguno"
PY=""
if command -v jq >/dev/null 2>&1; then
  JSON_MODE="jq"
elif command -v python3 >/dev/null 2>&1; then
  JSON_MODE="py"; PY="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  JSON_MODE="py"; PY="$(command -v python)"
fi
export PYTHONIOENCODING=utf-8   # emojis en consolas Windows (cp1252)

GRAFANA_PORT="$(docker compose port lgtm 3000 2>/dev/null | awk -F: '{print $NF}')"
G="http://localhost:${GRAFANA_PORT:-3000}"

icono_estado() {  # traduce el estado de la API a algo legible
  sed -e 's/\binactive\b/🟢 Normal/' \
      -e 's/\bpending\b/🟡 Pending/' \
      -e 's/\bfiring\b/🔴 FIRING/' \
      -e 's/\bnodata\b/⚪ Sin datos/'
}

mostrar_reglas() {
  local json="$1"
  if [ -z "$json" ]; then
    echo "   (Grafana no respondió — ¿corriste ./start.sh? dale unos segundos más)"
    return
  fi
  case "$JSON_MODE" in
    jq)
      printf '%s' "$json" \
        | jq -r '.data.groups[]?.rules[]? | "   \(.name): \(.state)"' 2>/dev/null \
        | icono_estado
      ;;
    py)
      printf '%s' "$json" | "$PY" -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('   (respuesta ilegible de Grafana)'); raise SystemExit
iconos = {'inactive': '🟢 Normal', 'pending': '🟡 Pending', 'firing': '🔴 FIRING', 'nodata': '⚪ Sin datos'}
for g in d.get('data', {}).get('groups', []):
    for r in g.get('rules', []):
        st = r.get('state', '?')
        print(f\"   {r.get('name','?')}: {iconos.get(st, st)}\")
"
      ;;
    *)
      # Sin jq ni python: extracción mínima pero suficiente para ver el estado.
      printf '%s' "$json" | tr ',' '\n' | grep -o '"state":"[a-z]*"' \
        | cut -d'"' -f4 | head -1 | icono_estado \
        | sed 's/^/   Checkout con tasa de error alta: /'
      ;;
  esac
}

mostrar_notificaciones() {
  local json="$1"
  if [ -z "$json" ]; then
    echo "   (Loki no respondió todavía)"
    return
  fi
  local lineas
  case "$JSON_MODE" in
    jq)  lineas="$(printf '%s' "$json" | jq -r '.data.result[]?.values[]? | .[1]' 2>/dev/null | tail -5)" ;;
    py)  lineas="$(printf '%s' "$json" | "$PY" -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
out = []
for s in d.get('data', {}).get('result', []):
    for ts, linea in s.get('values', []):
        out.append((ts, linea))
for ts, linea in sorted(out)[-5:]:
    print(linea)
")" ;;
    *)   lineas="$(printf '%s' "$json" | grep -o 'ALERTA[^\"]*' | tail -5)" ;;
  esac
  if [ -z "$lineas" ]; then
    echo "   (ninguna en la última hora — dispárala con: ./alerta.sh probar)"
  else
    printf '   %s\n' "$lineas" | cut -c1-118
  fi
}

case "${1:-estado}" in
  probar)
    cat <<'EOF'
════════════════════════════════════════════════════════════
 CÓMO PROBAR LA ALERTA (todo local, con las perillas)
════════════════════════════════════════════════════════════
  1. ./ajustar.sh fallo 60     # supera el umbral (40%)
  2. espera ~1-2 min           # Normal -> Pending -> FIRING 🔔
     ./alerta.sh               # míralo cambiar (o Grafana -> Alerting -> Alert rules)
  3. ./alerta.sh               # la notificación del webhook, guardada en Loki
  4. ./ajustar.sh fallo 0      # "el fix" -> en ~1 min pasa a Resolved ✅
  5. ./ajustar.sh reset        # vuelve a los valores del taller

 ¿POR QUÉ TARDA 1-2 MINUTOS? Es anti-ruido: la regla se evalúa cada 30 s y exige
 que la condición se SOSTENGA 1 minuto (`for: 1m`) antes de despertar a nadie.
EOF
    ;;
  estado|*)
    if [ "$JSON_MODE" = "ninguno" ]; then
      echo "⚠️  No encontré 'jq' ni 'python' para leer las respuestas JSON."
      echo "    Verás una versión reducida. Para la completa: sudo apt-get install -y jq"
      echo
    fi

    echo "==> Estado de la regla (Grafana ${G}):"
    REGLAS="$(curl -s --max-time 10 -u admin:admin "${G}/api/prometheus/grafana/api/v1/rules" 2>/dev/null)"
    mostrar_reglas "$REGLAS"

    echo
    echo "==> Notificaciones que llegaron al webhook (leídas desde Loki):"
    NOW_NS=$(( $(date +%s) * 1000000000 ))
    START_NS=$(( NOW_NS - 3600000000000 ))   # última hora
    LOGS="$(docker compose exec -T lgtm curl -s -G "http://localhost:3100/loki/api/v1/query_range" \
        --data-urlencode 'query={service_name="checkout-api"} |= "ALERTA"' \
        --data-urlencode "start=${START_NS}" --data-urlencode "end=${NOW_NS}" \
        --data-urlencode "limit=5" 2>/dev/null)"
    mostrar_notificaciones "$LOGS"

    cat <<EOF

   ¿A DÓNDE LLEGAN LAS ALERTAS? Grafana -> webhook 'taller-webhook'
   -> POST http://app:8000/alerta (la propia app) -> la app lo loguea -> Loki.
   Verlas en la UI:    ${G} -> Alerting -> Alert rules      (admin / admin)
   Verlas como log:    ${G} -> Explore -> Loki -> {service_name="checkout-api"} |= "ALERTA"
EOF
    ;;
esac
