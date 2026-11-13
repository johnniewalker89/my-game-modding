FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY SC_Discord_Trader/requirements.lock /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY SC_Discord_Trader /build/SC_Discord_Trader
COPY SC_Patch_Alerts /build/SC_Patch_Alerts
COPY SC_Companion /build/SC_Companion
RUN pip install --no-deps --no-cache-dir /build/SC_Discord_Trader /build/SC_Patch_Alerts /build/SC_Companion \
    && pip check \
    && useradd --uid 10001 --create-home trader \
    && mkdir -p /data/trader /data/patches \
    && chown -R trader:trader /data
COPY SC_Companion/app.py /app/app.py
ARG SOURCE_FINGERPRINT=unknown
LABEL sc.companion.source-fingerprint=$SOURCE_FINGERPRINT
ENV TRADER_DATA_DIR=/data/trader
USER trader
CMD ["sc-companion-worker"]
