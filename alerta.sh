#!/usr/bin/env bash
# alerta.sh — ¿En qué estado está la ALERTA del taller? ¿Llegaron notificaciones?
#
# La regla "Checkout con tasa de error alta" (provisionada como código en
# grafana/provisioning/alerting/alertas.yml) dispara cuando >40% de los checkouts
# falla durante 1 min, y notifica por WEBHOOK a la propia app (/alerta), que lo
# loguea -> la notificación viaja a LOKI y este script la consulta AHÍ (los logs
# del contenedor se reinician al girar perillas; Loki es la memoria durable).
#
# Uso:
#   ./alerta.sh            # estado de la regla + últimas notificaciones (desde Loki)
#   ./alerta.sh probar     # receta para dispararla y resolverla con las perillas
set -euo pipefail

# python3 en Linux/Codespaces; python en Git Bash de Windows
PY="$(command -v python3 || command -v python)"
export PYTHONIOENCODING=utf-8   # emojis en consolas Windows (cp1252)

GRAFANA_PORT="$(docker compose port lgtm 3000 2>/dev/null | awk -F: '{print $NF}')"
G="http://localhost:${GRAFANA_PORT:-3000}"

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
EOF
    ;;
  estado|*)
    echo "==> Estado de la regla (Grafana ${G}):"
    curl -s -u admin:admin "${G}/api/prometheus/grafana/api/v1/rules" | "$PY" -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('   (Grafana aún no responde — ./start.sh primero, o dale unos segundos)'); raise SystemExit
for g in d.get('data', {}).get('groups', []):
    for r in g.get('rules', []):
        estado = r.get('state', '?')
        icono = {'inactive': '🟢 Normal', 'pending': '🟡 Pending', 'firing': '🔴 FIRING'}.get(estado, estado)
        print(f\"   {r.get('name','?')}: {icono}\")
" || echo "   (no pude consultar Grafana)"
    echo
    echo "==> Últimas notificaciones del webhook (guardadas en Loki):"
    NOW_NS=$(( $(date +%s) * 1000000000 ))
    START_NS=$(( NOW_NS - 3600000000000 ))   # última hora
    docker compose exec -T lgtm curl -s -G "http://localhost:3100/loki/api/v1/query_range" \
        --data-urlencode 'query={service_name="checkout-api"} |= "ALERTA"' \
        --data-urlencode "start=${START_NS}" --data-urlencode "end=${NOW_NS}" \
        --data-urlencode "limit=5" 2>/dev/null | "$PY" -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('   (Loki aún no responde)'); raise SystemExit
lineas = []
for s in d.get('data', {}).get('result', []):
    for ts, linea in s.get('values', []):
        lineas.append((ts, linea))
if not lineas:
    print('   (ninguna en la última hora — dispárala con: ./alerta.sh probar)')
for ts, linea in sorted(lineas)[-5:]:
    print('   ' + linea[:110])
" || echo "   (no pude consultar Loki)"
    echo
    echo "   UI: ${G} -> Alerting -> Alert rules   (admin / admin)"
    ;;
esac
