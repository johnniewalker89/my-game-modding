FROM python:3.12-slim
ARG SOURCE_FINGERPRINT=unknown
LABEL org.opencontainers.image.title="SC Patch Alerts local MVP" sc.source-fingerprint=$SOURCE_FINGERPRINT
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY pyproject.toml README.md LICENSE ./
COPY patch_alerts ./patch_alerts
COPY tests ./tests
RUN pip install --no-cache-dir --no-deps . \
    && useradd --uid 10002 --create-home patchalerts \
    && mkdir /data && chown patchalerts:patchalerts /data
USER patchalerts
EXPOSE 8080
CMD ["sc-patch-alerts", "serve", "--data-dir", "/data", "--port", "8080"]
