FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY requirements.lock .
RUN pip install --no-cache-dir -r requirements.lock
COPY pyproject.toml requirements.in README.md DEPLOYMENT.md LICENSE LICENSE-SCOPE.md BRANDING.md THIRD_PARTY_NOTICES.md SECURITY.md ./
COPY trader ./trader
RUN pip install --no-deps --no-cache-dir . \
    && useradd --uid 10001 --create-home trader \
    && mkdir /data && chown trader:trader /data
COPY tests ./tests
USER trader
EXPOSE 8765
CMD ["sc-discord-trader-worker"]
