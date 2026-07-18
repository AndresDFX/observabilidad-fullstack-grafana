"""
loadgen — generador de carga con httpx.

Golpea los endpoints de checkout-api en bucle para llenar los dashboards y provocar
errores (/checkout ~20%) y latencia (/slow). No exporta telemetría propia: su trabajo
es SOLO producir tráfico realista para que la demo tenga qué observar.

Mezcla de tráfico (peso): / (70%), /slow (20%), /checkout (10%). Ese 10% de checkouts
con un 20% de fallo mantiene visible un pico de errores en el panel RED.

Variables de entorno:
  TARGET_BASE_URL  URL base de la API (por defecto http://app:8000)
  RPS              peticiones por segundo aproximadas (por defecto 8)
"""
import os
import random
import time

import httpx

BASE_URL = os.getenv("TARGET_BASE_URL", "http://app:8000")
RPS = float(os.getenv("RPS", "8"))
INTERVAL = 1.0 / RPS if RPS > 0 else 0.125

# (ruta, peso)
ENDPOINTS = [
    ("/", 70),
    ("/slow", 20),
    ("/checkout", 10),
]
ROUTES = [r for r, _ in ENDPOINTS]
WEIGHTS = [w for _, w in ENDPOINTS]


def main() -> None:
    print(f"[loadgen] target={BASE_URL} rps~{RPS}", flush=True)

    # Espera activa a que la API responda antes de empezar el bucle.
    with httpx.Client(base_url=BASE_URL, timeout=10.0) as client:
        for _ in range(60):
            try:
                client.get("/healthz")
                print("[loadgen] API arriba, generando carga...", flush=True)
                break
            except httpx.HTTPError:
                print("[loadgen] esperando a la API...", flush=True)
                time.sleep(2)

        sent = 0
        errors = 0
        while True:
            route = random.choices(ROUTES, weights=WEIGHTS, k=1)[0]
            try:
                resp = client.get(route)
                sent += 1
                if resp.status_code >= 500:
                    errors += 1
            except httpx.HTTPError:
                errors += 1

            if sent % 100 == 0 and sent > 0:
                print(f"[loadgen] enviadas={sent} errores_5xx~={errors}", flush=True)

            time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
