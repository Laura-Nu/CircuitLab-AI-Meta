.PHONY: install migrate api worker test contracts client web
install:
	cd services/backend && uv sync --frozen
migrate:
	cd services/backend && uv run alembic upgrade head
api:
	cd services/backend && uv run uvicorn app.main:app --reload --host 127.0.0.1
worker:
	cd services/backend && uv run python -m app.worker
test:
	cd services/backend && uv run pytest -q && uv run ruff check .
	cd services/bridge && uv run pytest -q
	cd apps/client && flutter analyze && flutter test
contracts:
	cd services/backend && uv run python ../../scripts/export_contracts.py
client:
	cd apps/client && flutter run -d chrome --web-port 8080
web:
	cd apps/client && flutter build web --base-href /app/ --dart-define=API_BASE_URL=/api/v1
	python scripts/build_site.py
