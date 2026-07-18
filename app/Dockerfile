FROM python:3.12-slim

# No escribir .pyc y logs sin buffer (se ven al instante en `docker compose logs`)
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8000

# La instrumentación de OpenTelemetry se configura dentro de main.py, así que
# arrancamos uvicorn tal cual. (Alternativa equivalente: envolver con
# `opentelemetry-instrument uvicorn main:app ...` tras instalar opentelemetry-distro.)
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
