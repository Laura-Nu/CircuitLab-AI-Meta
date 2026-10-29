"""Board/module context and sensor values without changing existing observations."""
from alembic import op
import sqlalchemy as sa

revision = "0010"
down_revision = "0009"


def upgrade():
    op.add_column("sessions", sa.Column("setup", sa.String(), nullable=False, server_default=""))
    op.add_column("measurements", sa.Column("text_value", sa.String(500), nullable=True))


def downgrade():
    db = op.get_bind()
    if db.scalar(sa.text("SELECT count(*) FROM measurements WHERE unit NOT IN ('V', 'boolean')")):
        raise RuntimeError("Sensor observations exist; refusing a destructive downgrade")
    if db.scalar(sa.text("SELECT count(*) FROM sessions WHERE setup <> '' OR family IN ('microcontroller','custom')")):
        raise RuntimeError("Project context exists; refusing a destructive downgrade")
    op.drop_column("measurements", "text_value")
    op.drop_column("sessions", "setup")
