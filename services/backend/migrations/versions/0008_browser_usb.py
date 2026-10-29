"""Add an authenticated browser USB transport without changing legacy bridges."""
from alembic import op
import sqlalchemy as sa

revision = "0008"
down_revision = "0007"


def upgrade():
    op.add_column("devices", sa.Column("transport", sa.String(), nullable=False, server_default="bridge"))
    op.add_column("hardware_commands", sa.Column("browser_connection_id", sa.String(), nullable=True))
    op.create_table("browser_usb_connections",
                    sa.Column("device_id", sa.String(), sa.ForeignKey("devices.id"), primary_key=True),
                    sa.Column("id", sa.String(), nullable=False),
                    sa.Column("lease_digest", sa.String(), nullable=False),
                    sa.Column("expires", sa.DateTime(timezone=True), nullable=False))


def downgrade():
    op.drop_table("browser_usb_connections")
    op.drop_column("hardware_commands", "browser_connection_id")
    op.drop_column("devices", "transport")
