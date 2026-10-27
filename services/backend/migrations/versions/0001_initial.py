"""Initial schema. Schema is frozen in this revision rather than imported from app models."""

from alembic import op
from pathlib import Path
import re

revision = "0001"
down_revision = None


def upgrade():
    # Generated SQL snapshot committed alongside this revision by export_contracts.py.
    sql = Path(__file__).with_name("0001_schema.sql").read_text(encoding="utf-8")
    for statement in sql.split(";\n"):
        if statement.strip():
            op.execute(statement.strip())


def downgrade():
    snapshot = Path(__file__).with_name("0001_schema.sql").read_text(encoding="utf-8")
    tables = re.findall(r"^CREATE TABLE ([a-z_]+)", snapshot, re.MULTILINE)
    for name in reversed(tables):
        op.drop_table(name)
