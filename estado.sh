#!/usr/bin/env bash
# estado.sh — ¿Cómo va todo? Servicios, perillas y URLs en un vistazo.
set -euo pipefail

echo "==> Servicios:"
docker compose ps

echo
echo "==> Perillas activas de la app:"
docker compose exec -T app sh -c 'echo "    CHECKOUT_FAILURE_RATE=${CHECKOUT_FAILURE_RATE}%  SLOW_SPIKE_RATE=${SLOW_SPIKE_RATE}%"' 2>/dev/null \
  || echo "    (la app no está corriendo — ./start.sh primero)"

# Descubre los puertos publicados (soporta mapeos alternativos).
GRAFANA_PORT="$(docker compose port lgtm 3000 2>/dev/null | awk -F: '{print $NF}')"
APP_PORT="$(docker compose port app 8000 2>/dev/null | awk -F: '{print $NF}')"

echo
echo "==> URLs:"
echo "    Grafana ......... http://localhost:${GRAFANA_PORT:-3000}   (admin / admin)"
echo "    API (checkout) .. http://localhost:${APP_PORT:-8000}"
echo
echo "    En GitHub Codespaces: pestaña Ports -> puerto ${GRAFANA_PORT:-3000} -> abrir la URL reenviada."
echo "    Dashboard: Dashboards -> 'Observabilidad Full-Stack' -> 'RED — checkout-api'"
