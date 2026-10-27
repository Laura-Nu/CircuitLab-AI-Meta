"""Persist the language used for new diagnostic work; existing sessions remain Spanish."""

from alembic import op
import sqlalchemy as sa

revision = "0002"
down_revision = "0001"


def upgrade():
    op.add_column("sessions", sa.Column("language", sa.String(2), nullable=False, server_default="es"))


def downgrade():
    op.drop_column("sessions", "language")
