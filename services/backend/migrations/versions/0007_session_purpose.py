"""Distinguish fault diagnosis from a symptom-free operation assessment."""
from alembic import op
import sqlalchemy as sa

revision = "0007"
down_revision = "0006"


def upgrade():
    op.add_column("sessions", sa.Column("purpose", sa.String(20), nullable=False, server_default="diagnosis"))


def downgrade():
    op.drop_column("sessions", "purpose")
