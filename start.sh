#!/usr/bin/env bash
# start.sh — PASO 1 del taller: construye y levanta TODO el stack con un comando.
set -euo pipefail

echo "==> Construyendo y levantando el stack (lgtm + app + loadgen)..."
docker compose up -d --build

echo
echo "==> Estado de los servicios:"
docker compose ps

# Descubre los puertos publicados (soporta mapeos alternativos).
GRAFANA_PORT="$(docker compose port lgtm 3000 2>/dev/null | awk -F: '{print $NF}')"
APP_PORT="$(docker compose port app 8000 2>/dev/null | awk -F: '{print $NF}')"

cat <<EOF

============================================================
  Stack de observabilidad ARRIBA ✅
============================================================
  Grafana ............ http://localhost:${GRAFANA_PORT:-3000}   (admin / admin)
  API (checkout) ..... http://localhost:${APP_PORT:-8000}/   ·  /slow  ·  /checkout  ·  /healthz
  (En Codespaces: pestaña Ports -> puerto ${GRAFANA_PORT:-3000} -> abrir la URL reenviada)

  Dashboard RED:  Grafana -> Dashboards -> "Observabilidad Full-Stack" -> "RED — checkout-api"
  Dale ~30 s a que la telemetría empiece a llenar los paneles (el loadgen ya trabaja).

  EL RESTO DEL TALLER SON ESTOS SCRIPTS (en este orden):
    ./trafico.sh pico        -> provoca un pico de errores      (míralo aparecer en Errors)
    ./trafico.sh lento       -> provoca un pico de latencia     (míralo en el p95 de Duration)
    ./ajustar.sh fallo 50    -> INCIDENTE: 50% de checkouts caen (mira Errors dispararse)
    ./ajustar.sh fallo 0     -> "el fix": mira la recuperación en vivo 📉
    ./alerta.sh              -> ¿la ALERTA está Normal/Pending/FIRING? + notificaciones 🔔
    ./ajustar.sh reset       -> vuelve a los valores del taller
    ./estado.sh              -> servicios, perillas y URLs
    ./stop.sh                -> detener y limpiar TODO
============================================================
EOF
