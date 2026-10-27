"""Run from services/backend: python ../../scripts/export_contracts.py [--initial-schema]."""

import json
import sys
from pathlib import Path
from sqlalchemy.schema import CreateIndex, CreateTable
from sqlalchemy.dialects import postgresql

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services/backend"))
from app.main import app  # noqa: E402
from app.db import Base  # noqa: E402
from app.schemas import HardwareCommand, HardwareResult  # noqa: E402

root = Path(__file__).resolve().parents[1]
destination = root / "contracts"
destination.mkdir(exist_ok=True)
for filename, schema in [
    ("openapi.json", app.openapi()),
    ("hardware_command.schema.json", HardwareCommand.model_json_schema()),
    ("hardware_result.schema.json", HardwareResult.model_json_schema()),
]:
    (destination / filename).write_text(
        json.dumps(schema, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
if "--initial-schema" in sys.argv:
    statements = []
    # This schema uses portable DDL shared by SQLite tests and PostgreSQL.
    for table in Base.metadata.sorted_tables:
        statements.append(str(CreateTable(table).compile(dialect=postgresql.dialect())).strip())
        statements.extend(str(CreateIndex(i).compile(dialect=postgresql.dialect())) for i in table.indexes)
    (root / "services/backend/migrations/versions/0001_schema.sql").write_text(
        ";\n".join(statements) + ";\n", encoding="utf-8"
    )
