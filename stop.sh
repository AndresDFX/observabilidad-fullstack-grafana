#!/usr/bin/env bash
# Detiene el stack y borra contenedores, red y volúmenes (telemetría incluida).
set -euo pipefail

echo "==> Deteniendo y eliminando el stack (contenedores + red + volúmenes)..."
docker compose down -v

echo "==> Listo. No queda nada corriendo."
echo "    (Las imágenes construidas siguen en caché; bórralas con 'docker image prune' si quieres.)"
