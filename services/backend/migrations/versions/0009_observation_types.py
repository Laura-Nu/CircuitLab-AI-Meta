"""Preserve withdrawn evidence metadata and store boolean observations separately."""
from alembic import op
import sqlalchemy as sa

revision = "0009"
down_revision = "0008"


def upgrade():
    op.add_column("evidence", sa.Column("removed_at", sa.DateTime(timezone=True), nullable=True))
    with op.batch_alter_table("measurements") as batch:
        batch.alter_column("value", existing_type=sa.Float(), nullable=True)
        batch.add_column(sa.Column("boolean_value", sa.Boolean(), nullable=True))


def downgrade():
    connection = op.get_bind()
    if connection.scalar(sa.text("SELECT count(*) FROM measurements WHERE unit = 'boolean'")):
        raise RuntimeError("Boolean observations exist; refusing a destructive downgrade")
    if connection.scalar(sa.text("SELECT count(*) FROM evidence WHERE removed_at IS NOT NULL")):
        raise RuntimeError("Withdrawn evidence exists; refusing to reactivate its metadata")
    with op.batch_alter_table("measurements") as batch:
        batch.drop_column("boolean_value")
        batch.alter_column("value", existing_type=sa.Float(), nullable=False)
    op.drop_column("evidence", "removed_at")
