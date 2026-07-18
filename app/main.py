"""
checkout-api — API demo instrumentada con OpenTelemetry (traces + metrics + logs).

Exporta las TRES señales por OTLP/HTTP al contenedor grafana/otel-lgtm, que las
enruta a Prometheus (métricas), Tempo (trazas) y Loki (logs). El objetivo del taller
es CORRELACIONARLAS: un exemplar en una métrica lleva a la traza, y la traza lleva al
log exacto por `trace_id`.

Puntos clave para el workshop:
  * Métricas RED (Rate, Errors, Duration) recogidas en un middleware, con nombres que
    se traducen a Prometheus como `http_requests_total` y `http_request_duration_seconds`.
  * El histograma de duración se graba mientras el span de servidor de OTel está activo
    (por eso su middleware debe ser el más EXTERNO), así el filtro de exemplars
    `trace_based` le adjunta el `trace_id` -> ese es el salto métrica->traza.
  * En /checkout, cuando el "pago" falla, se marca el span como ERROR y se emite un log
    de nivel ERROR. Ese log viaja a Loki con el mismo `trace_id` -> salto traza->log.

Arranque: `uvicorn main:app` (la instrumentación se configura aquí, en el import).
Alternativa equivalente sin tocar código: `opentelemetry-instrument uvicorn main:app`.
"""
from __future__ import annotations

import asyncio
import logging
import os
import random

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

# --- OpenTelemetry: API ---
from opentelemetry import metrics, trace
from opentelemetry.trace import Status, StatusCode

# --- OpenTelemetry: SDK (traces) ---
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# --- OpenTelemetry: SDK (metrics) ---
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader

# --- OpenTelemetry: SDK (logs) ---
from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor

# --- Exportadores OTLP/HTTP (una sola dependencia, sin gRPC) ---
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter

# --- Instrumentación automática de FastAPI (spans por request) ---
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

# (El trace_id en los logs de consola se inyecta con un logging.Filter propio -> ver más abajo.
#  No usamos opentelemetry-instrumentation-logging: en 0.64b0 no poblaba `otelTraceID` de forma
#  fiable, y el %(otelTraceID)s ausente reventaba el formateo y tumbaba el request.)

# ---------------------------------------------------------------------------
# 1) Recurso: identifica el servicio en las tres señales.
#    Resource.create() lee OTEL_SERVICE_NAME y OTEL_RESOURCE_ATTRIBUTES del entorno.
# ---------------------------------------------------------------------------
resource = Resource.create()

# ---------------------------------------------------------------------------
# 2) Trazas
# ---------------------------------------------------------------------------
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer("checkout-api")

# ---------------------------------------------------------------------------
# 3) Métricas
#    PeriodicExportingMetricReader lee OTEL_METRIC_EXPORT_INTERVAL del entorno.
# ---------------------------------------------------------------------------
metric_reader = PeriodicExportingMetricReader(OTLPMetricExporter())
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)
meter = metrics.get_meter("checkout-api")

# Counter -> en Prometheus: http_requests_total{route,method,status_code}
REQUESTS = meter.create_counter(
    name="http_requests",
    description="Total de peticiones HTTP atendidas (RED: Rate + Errors)",
)

# Histogram -> en Prometheus: http_request_duration_seconds_bucket/_count/_sum
# Buckets adecuados para SEGUNDOS (los de por defecto asumen 0..10000 y romperían p95).
DURATION = meter.create_histogram(
    name="http_request_duration",
    unit="s",
    description="Duración de las peticiones HTTP en segundos (RED: Duration)",
    explicit_bucket_boundaries_advisory=[
        0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0,
    ],
)

# ---------------------------------------------------------------------------
# 4) Logs -> se adjuntan al root logger; el LoggingHandler de OTel inyecta el
#    trace_id/span_id del span activo y exporta por OTLP hacia Loki.
# ---------------------------------------------------------------------------
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
set_logger_provider(logger_provider)

class _TraceContextFilter(logging.Filter):
    """Garantiza que TODO LogRecord tenga otelTraceID/otelSpanID (del span activo, o '0').

    Sin esto, el formato de consola que imprime %(otelTraceID)s reventaría con
    'Formatting field not found in record' en cada log y —peor— ese error se propaga y tumba
    el request (500). El MISMO trace_id viaja a Loki automáticamente vía el LoggingHandler de
    OTel (no depende de este filtro), así que la correlación traza->log en Grafana funciona igual.
    """

    def filter(self, record):
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            record.otelTraceID = format(ctx.trace_id, "032x")
            record.otelSpanID = format(ctx.span_id, "016x")
        else:
            record.otelTraceID = "0"
            record.otelSpanID = "0"
        return True


_otel_handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [trace_id=%(otelTraceID)s] %(message)s",
    handlers=[logging.StreamHandler(), _otel_handler],
)
# Aplica el filtro a los handlers del root: así ven TODOS los records (incluidos los propagados
# desde loggers hijos como "checkout-api") y les fijan otelTraceID ANTES de formatear.
for _h in logging.getLogger().handlers:
    _h.addFilter(_TraceContextFilter())
log = logging.getLogger("checkout-api")

# ---------------------------------------------------------------------------
# 5) Las "perillas" del taller (ajustables en vivo con ./ajustar.sh)
#    Se leen del entorno como PORCENTAJES (0-100). Cambiarlas y recrear el
#    contenedor (docker compose up -d app) es el corazón del formato del taller:
#    giras una perilla -> miras el dashboard reaccionar.
# ---------------------------------------------------------------------------
def _pct(env_name: str, default: str) -> float:
    try:
        value = float(os.getenv(env_name, default))
    except ValueError:
        value = float(default)
    return max(0.0, min(100.0, value)) / 100.0


CHECKOUT_FAILURE_RATE = _pct("CHECKOUT_FAILURE_RATE", "20")  # % de checkouts que fallan (503)
SLOW_SPIKE_RATE = _pct("SLOW_SPIKE_RATE", "15")              # % de /slow con pico de latencia

log.info(
    "perillas: CHECKOUT_FAILURE_RATE=%d%% | SLOW_SPIKE_RATE=%d%%",
    round(CHECKOUT_FAILURE_RATE * 100),
    round(SLOW_SPIKE_RATE * 100),
)

# ---------------------------------------------------------------------------
# 6) App FastAPI
# ---------------------------------------------------------------------------
app = FastAPI(title="checkout-api", version="1.0.0")


@app.middleware("http")
async def red_metrics(request, call_next):
    """Middleware RED: cuenta peticiones y mide duración por ruta/método/status.

    OJO AL ORDEN: la métrica se graba en el `finally`, DESPUÉS de que el handler terminó.
    Para que el histograma reciba un exemplar con el `trace_id` (filtro `trace_based`), el
    span de servidor de OTel debe seguir activo en ese momento. Por eso instrumentamos
    FastAPI DESPUÉS de registrar este middleware (así OTel queda más EXTERNO y su span
    envuelve a red_metrics). Ese exemplar es el que enlaza la métrica con la traza.
    """
    if request.url.path in ("/healthz", "/alerta"):
        return await call_next(request)

    import time

    start = time.perf_counter()
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        elapsed = time.perf_counter() - start
        attrs = {
            "route": request.url.path,
            "method": request.method,
            "status_code": str(status_code),
        }
        REQUESTS.add(1, attrs)
        DURATION.record(elapsed, attrs)


# Instrumenta FastAPI DESPUÉS del middleware RED: así el span de servidor de OTel queda como
# el middleware más EXTERNO y sigue activo cuando red_metrics graba el histograma en su
# `finally` -> el filtro `trace_based` le adjunta el exemplar con el trace_id. Excluye healthz
# para no ensuciar las trazas con los healthchecks de Docker.
FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,alerta")


@app.get("/")
async def root():
    """Endpoint rápido: respuesta inmediata."""
    return {"service": "checkout-api", "status": "ok"}


@app.get("/slow")
async def slow():
    """Latencia variable: la mayoría rápido, con picos ocasionales (cola larga)."""
    with tracer.start_as_current_span("query_inventory") as span:
        # SLOW_SPIKE_RATE (perilla, def. 15%) de las veces se dispara la latencia
        # (dependencia lenta simulada). Ajústala con: ./ajustar.sh latencia <0-100>
        if random.random() < SLOW_SPIKE_RATE:
            delay = random.uniform(1.0, 2.5)
            span.set_attribute("inventory.cache_hit", False)
        else:
            delay = random.uniform(0.05, 0.4)
            span.set_attribute("inventory.cache_hit", True)
        span.set_attribute("inventory.delay_seconds", round(delay, 3))
        await asyncio.sleep(delay)
    return {"endpoint": "/slow", "delay_seconds": round(delay, 3)}


@app.get("/checkout")
async def checkout():
    """Falla CHECKOUT_FAILURE_RATE% de las veces (perilla, def. 20%) simulando un
    timeout de la pasarela de pago. Ajústala con: ./ajustar.sh fallo <0-100>

    Cuando falla: marca el span como ERROR y emite un log de nivel ERROR con el
    trace_id. Ese log es la 'causa raíz' que revela el drill-down en la demo.
    """
    order_id = f"ord-{random.randint(10000, 99999)}"

    with tracer.start_as_current_span("validate_cart") as span:
        span.set_attribute("order.id", order_id)
        await asyncio.sleep(random.uniform(0.02, 0.08))

    with tracer.start_as_current_span("charge_payment") as span:
        span.set_attribute("order.id", order_id)
        span.set_attribute("payment.gateway", "stripe-sim")

        if random.random() < CHECKOUT_FAILURE_RATE:
            # Falla del pago = TIMEOUT de la pasarela: se cuelga ~3 s y LUEGO falla.
            # Clave para la demo: al ser LENTO, un checkout fallido produce un exemplar
            # en la ZONA ALTA del panel de latencia. Así "clic en el diamante más alto"
            # cae de forma fiable en una traza con este span en ERROR (no en un /slow).
            timeout_s = random.uniform(2.8, 3.5)
            span.set_attribute("payment.timeout_seconds", round(timeout_s, 2))
            await asyncio.sleep(timeout_s)
            span.set_attribute("payment.outcome", "declined")
            span.set_status(Status(StatusCode.ERROR, "payment gateway timeout"))
            span.record_exception(RuntimeError("payment gateway timeout after 3s"))
            log.error(
                "checkout failed: payment gateway timeout after 3s (order_id=%s)",
                order_id,
            )
            raise HTTPException(status_code=503, detail="payment gateway timeout")

        # Pago exitoso: rápido.
        await asyncio.sleep(random.uniform(0.05, 0.2))
        span.set_attribute("payment.outcome", "approved")

    log.info("checkout ok (order_id=%s)", order_id)
    return {"endpoint": "/checkout", "order_id": order_id, "status": "approved"}


@app.post("/alerta")
async def alerta(request: Request):
    """Webhook de ALERTAS de Grafana (contact point 'taller-webhook').

    Cuando la regla "Checkout con tasa de error alta" dispara (o se resuelve), Grafana
    hace POST aquí. Logueamos la notificación -> el log viaja a Loki -> la alerta misma
    se vuelve observable en el mismo stack. (En producción esto sería Slack/PagerDuty.)
    Pruébalo con: ./ajustar.sh fallo 50   (y resuélvela con ./ajustar.sh fallo 0)
    """
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    estado = payload.get("status", "desconocido")          # "firing" | "resolved"
    titulo = payload.get("title") or payload.get("commonLabels", {}).get("alertname", "alerta")
    resumen = (payload.get("commonAnnotations") or {}).get("summary", "")
    if estado == "firing":
        log.warning("🔔 ALERTA FIRING: %s — %s", titulo, resumen)
    else:
        log.info("✅ ALERTA %s: %s", estado.upper(), titulo)
    return JSONResponse({"recibida": True, "estado": estado})


@app.get("/healthz")
async def healthz():
    """Liveness probe (excluido de métricas y trazas)."""
    return JSONResponse({"status": "healthy"})
