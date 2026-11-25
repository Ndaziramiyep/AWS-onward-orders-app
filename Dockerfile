# ---- Stage 1: build wheels (has pip cache and build tools, thrown away afterwards)
FROM python:3.12-slim AS build

# Build directory
WORKDIR /build
COPY app/requirements.txt .
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# ---- Stage 2: small runtime image
FROM python:3.12-slim
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

# App directory
WORKDIR /srv
COPY --from=build /wheels /wheels
RUN pip install --no-cache-dir --no-index /wheels/* && rm -rf /wheels
COPY app/ .

# Unprivileged user (never run as root)
RUN useradd --system --uid 10001 --no-create-home appuser

# Switch to it
USER appuser
EXPOSE 8080
CMD ["gunicorn", "-b", "0.0.0.0:8080", "-w", "2", "--threads", "4", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "main:app"]
