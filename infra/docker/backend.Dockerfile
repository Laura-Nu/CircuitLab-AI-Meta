FROM python:3.12.10-slim
COPY --from=ghcr.io/astral-sh/uv:0.9.5 /uv /usr/local/bin/uv
WORKDIR /app
COPY services/backend/pyproject.toml services/backend/uv.lock ./
RUN uv sync --frozen --no-dev
COPY services/backend/app ./app
COPY services/backend/migrations ./migrations
COPY services/backend/alembic.ini ./
RUN useradd --create-home --uid 10001 circuitlab && mkdir -p /data/evidence && chown -R circuitlab:circuitlab /data /app
USER circuitlab
ENV PATH="/app/.venv/bin:$PATH"
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "127.0.0.1"]
