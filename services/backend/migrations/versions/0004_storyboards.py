"""Immutable source snapshots for evidence-linked Circuit Stories."""

from alembic import op
import sqlalchemy as sa
from app.db import UTCInstant, Payload

revision = "0004"
down_revision = "0003"


def upgrade():
    op.create_table(
        "storyboards",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("session_id", sa.String(), sa.ForeignKey("sessions.id"), nullable=False),
        sa.Column("created_at", UTCInstant(), nullable=False),
        sa.Column("job_id", sa.String(), sa.ForeignKey("analysis_jobs.id"), nullable=False, unique=True),
        sa.Column("source_sha256", sa.String(64), nullable=False),
        sa.Column("source_version", sa.Integer(), nullable=False),
        sa.Column("snapshot", Payload, nullable=False),
        sa.Column("data", Payload),
        sa.UniqueConstraint("session_id", "source_sha256"),
    )
    op.create_index("ix_storyboards_session_id", "storyboards", ["session_id"])


def downgrade():
    op.drop_index("ix_storyboards_session_id", "storyboards")
    op.drop_table("storyboards")
