# syntax=docker/dockerfile:1
# ---- Stage 1: test -----------------------------------------------------------
# Runs the unit tests at build time and byte-compiles the app. If the tests
# fail, the image is never produced. Nothing from this stage except the app
# file reaches the runtime image (no test code, no build caches).
FROM python:3.13.9-alpine3.22 AS test
WORKDIR /src
COPY app.py test_app.py ./
RUN python -m unittest -v test_app \
 && mkdir /out && cp app.py /out/ \
 && python -m compileall -q /out

# ---- Stage 2: runtime --------------------------------------------------------
FROM python:3.13.9-alpine3.22 AS runtime

# Fixed numeric UID/GID so Kubernetes `runAsNonRoot` can verify it without
# resolving a username, and so it matches the chart's securityContext.
RUN addgroup -S -g 10001 app && adduser -S -D -H -u 10001 -G app app

WORKDIR /app
COPY --from=test --chown=10001:10001 /out/ /app/

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

USER 10001:10001
EXPOSE 8080

# Exec form -> python is PID 1 and receives SIGTERM directly (graceful stop).
ENTRYPOINT ["python", "/app/app.py"]
