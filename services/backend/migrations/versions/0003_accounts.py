"""Account roles, revocation, audit and durable recovery throttling. No implicit promotion."""

from alembic import op
import sqlalchemy as sa
from app.db import UTCInstant, Payload

revision = "0003"
down_revision = "0002"


def upgrade():
    op.add_column("users", sa.Column("role", sa.String(10), nullable=False, server_default="member"))
    op.add_column("users", sa.Column("active", sa.Integer(), nullable=False, server_default="1"))
    op.create_table(
        "account_events",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("actor_id", sa.String(), sa.ForeignKey("users.id")),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("data", Payload, nullable=False),
        sa.Column("created_at", UTCInstant(), nullable=False),
    )
    op.create_index("ix_account_events_user_id", "account_events", ["user_id"])
    op.create_table(
        "recovery_limits",
        sa.Column("key", sa.String(64), primary_key=True),
        sa.Column("window", sa.Integer(), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
    )


def downgrade():
    op.drop_table("recovery_limits")
    op.drop_index("ix_account_events_user_id", "account_events")
    op.drop_table("account_events")
    op.drop_column("users", "active")
    op.drop_column("users", "role")
