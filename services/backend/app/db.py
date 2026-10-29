import time
import uuid
from datetime import UTC, datetime
from sqlalchemy import (
    Column,
    String,
    Integer,
    Float,
    Boolean,
    JSON,
    ForeignKey,
    UniqueConstraint,
    DateTime,
    create_engine,
    event,
)
from sqlalchemy.types import TypeDecorator
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, sessionmaker
from app.config import settings


def uid():
    return str(uuid.uuid4())


class Base(DeclarativeBase):
    pass


class UTCInstant(TypeDecorator):
    """Persist timezone-aware timestamps; expose epoch seconds consistently to the clients."""

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is None:
            return None
        return datetime.fromtimestamp(value, UTC) if isinstance(value, (float, int)) else value

    def process_result_value(self, value, dialect):
        if value is None:
            return None
        return value.replace(tzinfo=UTC).timestamp() if value.tzinfo is None else value.timestamp()


Payload = JSON().with_variant(JSONB(), "postgresql")


class User(Base):
    __tablename__ = "users"
    id = Column(String, primary_key=True, default=uid)
    email = Column(String, unique=True, nullable=False)
    password = Column(String, nullable=False)
    failed_attempts = Column(Integer, default=0, nullable=False)
    locked_until = Column(UTCInstant, default=0, nullable=False)
    role = Column(String(10), nullable=False, default="member", server_default="member")
    active = Column(Integer, nullable=False, default=1, server_default="1")


class AccountEvent(Base):
    __tablename__ = "account_events"
    id = Column(String, primary_key=True, default=uid)
    actor_id = Column(ForeignKey("users.id"), nullable=True)
    user_id = Column(ForeignKey("users.id"), nullable=False, index=True)
    kind = Column(String, nullable=False)
    data = Column(Payload, nullable=False, default=dict)
    created_at = Column(UTCInstant, nullable=False, default=time.time)


class RecoveryLimit(Base):
    __tablename__ = "recovery_limits"
    key = Column(String(64), primary_key=True)
    window = Column(Integer, nullable=False)
    attempts = Column(Integer, nullable=False)


class UsageCounter(Base):
    __tablename__ = "usage_counters"
    scope = Column(String(100), primary_key=True)
    day = Column(Integer, primary_key=True)
    attempts = Column(Integer, nullable=False, default=0)


class WorkerHeartbeat(Base):
    __tablename__ = "worker_heartbeats"
    id = Column(String, primary_key=True)
    last_seen = Column(UTCInstant, nullable=False)


class EmailDelivery(Base):
    __tablename__ = "email_deliveries"
    id = Column(String, primary_key=True, default=uid)
    user_id = Column(ForeignKey("users.id"), nullable=True, index=True)
    purpose = Column(String(30), nullable=False, default="password_recovery")
    provider = Column(String(20), nullable=False, default="resend")
    status = Column(String(30), nullable=False, default="pending")
    provider_id = Column(String(200), nullable=True)
    http_status = Column(Integer, nullable=True)
    created_at = Column(UTCInstant, nullable=False, default=time.time)
    updated_at = Column(UTCInstant, nullable=False, default=time.time)


class AuthSession(Base):
    __tablename__ = "auth_sessions"
    id = Column(String, primary_key=True, default=uid)
    user_id = Column(ForeignKey("users.id"), nullable=False, index=True)
    idle_expires = Column(UTCInstant, nullable=False)
    last_activity = Column(UTCInstant, nullable=False, default=time.time)


class Token(Base):
    __tablename__ = "tokens"
    digest = Column(String, primary_key=True)
    user_id = Column(ForeignKey("users.id"), nullable=False)
    kind = Column(String, nullable=False)
    expires = Column(UTCInstant, nullable=False)
    auth_session_id = Column(ForeignKey("auth_sessions.id"), nullable=True, index=True)


class Session(Base):
    __tablename__ = "sessions"
    id = Column(String, primary_key=True, default=uid)
    owner_id = Column(ForeignKey("users.id"), nullable=False, index=True)
    title = Column(String, nullable=False)
    family = Column(String, nullable=False)
    expected = Column(String, nullable=False)
    symptoms = Column(String, nullable=False)
    purpose = Column(String(20), nullable=False, default="diagnosis", server_default="diagnosis")
    supply_v = Column(Float, nullable=False)
    diagnosis_mode = Column(String, nullable=False, default=lambda: settings().ai_mode)
    language = Column(String(2), nullable=False, default="es", server_default="es")
    state = Column(String, nullable=False, default="draft")
    version = Column(Integer, nullable=False, default=1)
    specification = Column(Payload, nullable=False, default=dict)
    spec_version = Column(Integer, nullable=False, default=0)
    analysis_steps = Column(Integer, nullable=False, default=0)
    pending_test = Column(Payload, nullable=True)
    created_at = Column(UTCInstant, nullable=False, default=time.time)
    __mapper_args__ = {"version_id_col": version, "version_id_generator": False}


class Member(Base):
    __tablename__ = "session_members"
    session_id = Column(ForeignKey("sessions.id"), primary_key=True)
    user_id = Column(ForeignKey("users.id"), primary_key=True)
    role = Column(String, default="reader", nullable=False)


class RecordMixin:
    id = Column(String, primary_key=True, default=uid)
    session_id = Column(ForeignKey("sessions.id"), nullable=False, index=True)
    created_at = Column(UTCInstant, nullable=False, default=time.time)


class Evidence(RecordMixin, Base):
    __tablename__ = "evidence"
    key = Column(String, nullable=False, unique=True)
    mime = Column(String, nullable=False)
    sha256 = Column(String, nullable=False)
    size = Column(Integer, nullable=False)
    client_id = Column(String, nullable=False)
    removed_at = Column(UTCInstant, nullable=True)
    __table_args__ = (UniqueConstraint("session_id", "client_id"),)


class Measurement(RecordMixin, Base):
    __tablename__ = "measurements"
    client_id = Column(String, nullable=False)
    point_id = Column(String, nullable=False)
    value = Column(Float, nullable=True)
    boolean_value = Column(Boolean, nullable=True)
    unit = Column(String, nullable=False, default="V")
    source = Column(String, nullable=False)
    measured_at = Column(UTCInstant, nullable=False)
    calibration_id = Column(String, nullable=True)
    phase = Column(String, nullable=False, default="diagnosis")
    __table_args__ = (UniqueConstraint("session_id", "client_id"),)


class Hypothesis(RecordMixin, Base):
    __tablename__ = "hypotheses"
    data = Column(Payload, nullable=False)


class Intervention(RecordMixin, Base):
    __tablename__ = "interventions"
    description = Column(String, nullable=False)
    confirmed_by = Column(ForeignKey("users.id"), nullable=False)


class Verification(RecordMixin, Base):
    __tablename__ = "verifications"
    data = Column(Payload, nullable=False)


class Event(RecordMixin, Base):
    __tablename__ = "session_events"
    sequence = Column(Integer, nullable=False)
    kind = Column(String, nullable=False)
    data = Column(Payload, nullable=False)
    __table_args__ = (UniqueConstraint("session_id", "sequence"),)


class Job(RecordMixin, Base):
    __tablename__ = "analysis_jobs"
    kind = Column(String, nullable=False, default="analysis")
    status = Column(String, nullable=False, default="pending", index=True)
    attempts = Column(Integer, nullable=False, default=0)
    lease_until = Column(UTCInstant, nullable=False, default=0)
    lease_token = Column(String, nullable=True)
    error = Column(String, nullable=True)


class ModelRun(RecordMixin, Base):
    __tablename__ = "model_runs"
    data = Column(Payload, nullable=False)


class Storyboard(RecordMixin, Base):
    __tablename__ = "storyboards"
    job_id = Column(ForeignKey("analysis_jobs.id"), nullable=False, unique=True)
    source_sha256 = Column(String(64), nullable=False)
    source_version = Column(Integer, nullable=False)
    snapshot = Column(Payload, nullable=False)
    data = Column(Payload, nullable=True)
    __table_args__ = (UniqueConstraint("session_id", "source_sha256"),)


class Device(Base):
    __tablename__ = "devices"
    id = Column(String, primary_key=True, default=uid)
    owner_id = Column(ForeignKey("users.id"), nullable=False)
    name = Column(String, nullable=False)
    token_digest = Column(String, nullable=False, unique=True)
    points = Column(Payload, nullable=False)
    calibration_id = Column(String, nullable=False)
    simulated = Column(Integer, nullable=False, default=0)
    last_seen = Column(UTCInstant, nullable=True)
    transport = Column(String, nullable=False, default="bridge", server_default="bridge")


class BrowserUSBConnection(Base):
    __tablename__ = "browser_usb_connections"
    device_id = Column(ForeignKey("devices.id"), primary_key=True)
    id = Column(String, nullable=False, default=uid)
    lease_digest = Column(String, nullable=False)
    expires = Column(UTCInstant, nullable=False)


class Command(RecordMixin, Base):
    __tablename__ = "hardware_commands"
    browser_connection_id = Column(String, nullable=True)
    device_id = Column(ForeignKey("devices.id"), nullable=False)
    status = Column(String, nullable=False, default="pending")
    deadline = Column(UTCInstant, nullable=False)
    payload = Column(Payload, nullable=False)
    result = Column(Payload, nullable=True)


class Pairing(Base):
    __tablename__ = "pairings"
    digest = Column(String, primary_key=True)
    session_id = Column(ForeignKey("sessions.id"), nullable=False)
    expires = Column(UTCInstant, nullable=False)
    used = Column(Integer, nullable=False, default=0)


engine = create_engine(
    settings().database_url,
    pool_pre_ping=True,
    **(
        {"connect_args": {"check_same_thread": False}}
        if settings().database_url.startswith("sqlite")
        else {"pool_size": 5, "max_overflow": 2}
    ),
)
if engine.dialect.name == "sqlite":

    @event.listens_for(engine, "connect")
    def sqlite_fk(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")


SessionLocal = sessionmaker(engine, expire_on_commit=False)


def get_db():
    with SessionLocal() as db:
        yield db
