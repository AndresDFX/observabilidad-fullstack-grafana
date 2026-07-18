# Observabilidad Full-Stack con Grafana — código del workshop

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/AndresDFX/observabilidad-fullstack-grafana)

Stack de observabilidad **reproducible** con Docker Compose: una API instrumentada con
OpenTelemetry que emite las tres señales (métricas, trazas, logs) hacia el backend
**LGTM** (Loki, Grafana, Tempo, Prometheus/Mimir) todo-en-uno, con las **correlaciones**
ya configuradas para ir del síntoma a la causa raíz sin cambiar de herramienta.

## El taller en 6 scripts

El formato es simple: **construyes con un script, provocas/ajustas con otros, y cada acción se ve en
el dashboard**. No editas código ni YAML en vivo.

| Script | Qué hace | Qué VES en Grafana |
|---|---|---|
| `./start.sh` | **construye y levanta todo** (LGTM + app + tráfico) | los paneles RED se llenan |
| `./trafico.sh pico\|lento\|mixto` | provoca **ráfagas** de tráfico/errores/latencia | picos en Errors / Duration |
| `./ajustar.sh fallo\|latencia <0-100>` | **gira las perillas del sistema en vivo** | incidente 📈 y recuperación 📉 |
| `./alerta.sh` | estado de la **alerta** provisionada + notificaciones | 🔔 Normal → Pending → FIRING |
| `./estado.sh` | servicios, perillas activas y URLs | — |
| `./stop.sh` | detiene y **limpia todo** (`down -v`) | — |

```bash
./start.sh                 # 1. construye y levanta TODO (imprime URLs + mapa de scripts)
./trafico.sh pico          # 2. provoca un pico de errores  -> míralo en el dashboard
./ajustar.sh fallo 50      # 3. INCIDENTE: 50% de checkouts caen -> Errors se dispara
./ajustar.sh fallo 0       #    "el fix": la curva de errores cae en picada 📉
./alerta.sh                #    ¿la ALERTA está Normal/Pending/FIRING? + notificaciones 🔔
./stop.sh                  # 4. limpia todo
```

> Las tasas de fallo/latencia son **perillas** (variables de entorno). `./ajustar.sh` las escribe en
> `.env` y recrea solo el contenedor de la app (~2 s); la telemetría no se pierde (vive en `lgtm`).

## Dónde correrlo (3 entornos — el stack es el mismo)

Grafana queda en el puerto **3000** (`admin`/`admin`). Solo cambia **dónde** corre y con qué URL lo abres.

### 1) GitHub Codespaces (recomendado — sin instalar nada)

- Pulsa el badge **Open in GitHub Codespaces** de arriba (o **Code → Codespaces → Create codespace on main**).
- Espera a que se cree el entorno (Docker ya viene listo, definido en [`.devcontainer/devcontainer.json`](.devcontainer/devcontainer.json)).
- En la Terminal: `./start.sh`
- Pestaña **Ports** → puerto **3000** → abre la **URL reenviada** (`https://<codespace>-3000.app.github.dev`).

### 2) Google Cloud Shell (solo cuenta de Google)

```bash
git clone https://github.com/AndresDFX/observabilidad-fullstack-grafana.git
cd observabilidad-fullstack-grafana
./start.sh
```
Abre Grafana con **Web Preview → Change port → 3000**.

### 3) Docker local

```bash
git clone https://github.com/AndresDFX/observabilidad-fullstack-grafana.git
cd observabilidad-fullstack-grafana
./start.sh
```
Abre <http://localhost:3000>. Requiere **Docker Desktop** o **Docker Engine + plugin `compose`**.
(Si da "Permission denied": `chmod +x *.sh`, o antepón `bash`, p. ej. `bash start.sh`.)

---

El dashboard vive en **Dashboards → Observabilidad Full-Stack → "RED — checkout-api"**.
Dale ~30 s a que la telemetría llene los paneles (el `loadgen` ya está generando tráfico).

## Servicios

| Servicio | Qué es | Puertos |
|---|---|---|
| `lgtm` | `grafana/otel-lgtm`: Grafana + Prometheus + Tempo + Loki + OTel Collector | 3000 (UI), 4317 (OTLP gRPC), 4318 (OTLP HTTP) |
| `app` | `checkout-api` (FastAPI + OpenTelemetry) | 8000 |
| `loadgen` | genera tráfico contra la app | — |

## Endpoints de la app

| Endpoint | Comportamiento |
|---|---|
| `GET /` | rápido (respuesta inmediata) |
| `GET /slow` | latencia variable (picos ocasionales, cola larga) |
| `GET /checkout` | **falla ~20%** (timeout de pasarela) → span en ERROR + log de ERROR |
| `GET /healthz` | liveness (excluido de métricas y trazas) |

## Las tres correlaciones (el corazón del taller)

Configuradas en `grafana/provisioning/datasources/datasources.yml`:

1. **Métrica → traza (exemplars):** el panel de latencia p95/p99 muestra *diamantes*.
   Cada uno es una traza real; clic → **Ver traza** abre Tempo.
2. **Traza → log (`tracesToLogsV2`):** desde una traza en Tempo, "Logs for this span"
   consulta Loki filtrando por `trace_id` → el log exacto de la causa raíz.
3. **Log → traza (`derivedFields`):** desde un log en Loki, el campo `trace_id` es un
   enlace que te devuelve a la traza en Tempo.

## Provocar escenarios y girar las perillas

```bash
./trafico.sh pico        # ráfaga de checkouts -> pico en Errors
./trafico.sh lento       # ráfaga a /slow      -> sube el p95/p99 en Duration
./ajustar.sh fallo 50    # el 50% de checkouts falla (incidente)
./ajustar.sh fallo 0     # "el fix": recuperación en vivo
./ajustar.sh latencia 60 # 60% de /slow con picos de latencia
./ajustar.sh reset       # vuelve a los valores del taller (fallo 20, latencia 15)
./alerta.sh              # estado de la alerta (FIRING con fallo>=50) + notificaciones recibidas
./alerta.sh probar       # receta completa para dispararla y resolverla
./estado.sh              # servicios + perillas activas + URLs
```

Perillas disponibles (variables de entorno, 0–100):

| Variable | Qué controla | Default |
|---|---|---|
| `CHECKOUT_FAILURE_RATE` | % de `/checkout` que devuelve 503 | `20` |
| `SLOW_SPIKE_RATE` | % de `/slow` con pico de latencia (1–2.5 s) | `15` |

## Ver logs de cada servicio

```bash
docker compose logs -f app
docker compose logs -f lgtm
docker compose logs -f loadgen
```

## Parar y limpiar (¡importante!)

```bash
./stop.sh                   # = docker compose down -v (borra contenedores, red y volúmenes)
```

> ☁️ **En Codespaces**, además **detén o borra tu codespace** al terminar (github.com/codespaces →
> ⋯ → Stop/Delete) para no consumir horas del free tier.

## Estructura

```
.
├── .devcontainer/
│   └── devcontainer.json        # define el Codespace (Docker-in-Docker, puertos 3000/8000)
├── docker-compose.yml           # 3 servicios: lgtm, app, loadgen (+ perillas por env)
├── Guia-Participantes.md        # la guía paso a paso del taller (con sus imágenes en capturas/)
├── capturas/                    # screenshots reales + diagramas que usa la guía
├── start.sh                     # construye y levanta TODO (+ imprime el mapa de scripts)
├── trafico.sh                   # provoca ráfagas: pico | lento | mixto
├── ajustar.sh                   # gira las perillas en vivo: fallo | latencia | reset | estado
├── alerta.sh                    # estado de la ALERTA + notificaciones recibidas
├── estado.sh                    # servicios, perillas y URLs
├── stop.sh                      # detiene y limpia todo (down -v)
├── app/
│   ├── main.py                  # FastAPI + OpenTelemetry (traces + metrics + logs); perillas por env
│   ├── requirements.txt
│   └── Dockerfile
├── loadgen/
│   ├── loadgen.py               # httpx en bucle
│   └── Dockerfile
└── grafana/
    ├── provisioning/
    │   ├── datasources/datasources.yml   # Prometheus/Tempo/Loki + correlaciones
    │   ├── dashboards/dashboards.yml
    │   └── alerting/alertas.yml          # ALERTA como código: regla + webhook + política
    └── dashboards/red-dashboard.json     # dashboard RED con exemplars
```

## Notas de reproducibilidad

- El tag de la imagen `grafana/otel-lgtm` está **fijado** a `:0.28.0` (reproducibilidad del evento).
  Para actualizar, sube el número a un tag probado y valida el layout de provisioning.
- Los datasources se montan **sobre** los que trae otel-lgtm, con UIDs fijos
  (`prometheus`/`tempo`/`loki`) para que el dashboard y las correlaciones referencien
  siempre el mismo UID. La ruta de montaje asume el layout de otel-lgtm
  (`/otel-lgtm/grafana/conf/provisioning/...`).
