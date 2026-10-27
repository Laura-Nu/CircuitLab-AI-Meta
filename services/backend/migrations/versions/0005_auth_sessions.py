"""Persist browser/native idle sessions; existing accounts remain unchanged."""
from alembic import op
import sqlalchemy as sa
from app.db import UTCInstant

revision = "0005"
down_revision = "0004"


def upgrade():
    op.create_table("auth_sessions",
                    sa.Column("id", sa.String(), primary_key=True),
                    sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
                    sa.Column("idle_expires", UTCInstant(), nullable=False),
                    sa.Column("last_activity", UTCInstant(), nullable=False))
    op.create_index("ix_auth_sessions_user_id", "auth_sessions", ["user_id"])
    # Legacy tokens have no idle session; require sign-in once after this upgrade.
    op.execute("DELETE FROM tokens WHERE kind IN ('access', 'refresh')")
    with op.batch_alter_table("tokens") as batch:
        batch.add_column(sa.Column("auth_session_id", sa.String(), nullable=True))
        batch.create_foreign_key("fk_tokens_auth_session", "auth_sessions", ["auth_session_id"], ["id"])
        batch.create_index("ix_tokens_auth_session_id", ["auth_session_id"])


def downgrade():
    op.execute("DELETE FROM tokens WHERE auth_session_id IS NOT NULL")
    with op.batch_alter_table("tokens") as batch:
        batch.drop_index("ix_tokens_auth_session_id")
        batch.drop_constraint("fk_tokens_auth_session", type_="foreignkey")
        batch.drop_column("auth_session_id")
    op.drop_index("ix_auth_sessions_user_id", "auth_sessions")
    op.drop_table("auth_sessions")
