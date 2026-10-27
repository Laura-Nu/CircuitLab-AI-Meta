"""Persist usage budgets, worker presence and email delivery receipts."""

from alembic import op
import sqlalchemy as sa
from app.db import UTCInstant

revision = "0006"
down_revision = "0005"


def upgrade():
    op.create_table(
        "usage_counters",
        sa.Column("scope", sa.String(100), primary_key=True),
        sa.Column("day", sa.Integer(), primary_key=True),
        sa.Column("attempts", sa.Integer(), nullable=False),
    )
    op.create_table(
        "worker_heartbeats",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("last_seen", UTCInstant(), nullable=False),
    )
    op.create_table(
        "email_deliveries",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("purpose", sa.String(30), nullable=False),
        sa.Column("provider", sa.String(20), nullable=False),
        sa.Column("status", sa.String(30), nullable=False),
        sa.Column("provider_id", sa.String(200), nullable=True),
        sa.Column("http_status", sa.Integer(), nullable=True),
        sa.Column("created_at", UTCInstant(), nullable=False),
        sa.Column("updated_at", UTCInstant(), nullable=False),
    )
    op.create_index("ix_email_deliveries_user_id", "email_deliveries", ["user_id"])


def downgrade():
    op.drop_index("ix_email_deliveries_user_id", "email_deliveries")
    op.drop_table("email_deliveries")
    op.drop_table("worker_heartbeats")
    op.drop_table("usage_counters")
