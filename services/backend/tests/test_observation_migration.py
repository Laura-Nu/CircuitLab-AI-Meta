"""Migrate existing voltage records without loss; refuse destructive type downgrades."""
import time
from pathlib import Path
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, MetaData, Table, select, text
import pytest
from app import db as models


def test_existing_voltage_survives_and_boolean_blocks_destructive_downgrade(tmp_path, monkeypatch):
    root = Path(__file__).resolve().parents[1]
    engine = create_engine("sqlite:///" + (tmp_path / "migration.sqlite3").as_posix())
    monkeypatch.setattr(models, "engine", engine)
    config = Config(str(root / "alembic.ini"))
    config.set_main_option("script_location", str(root / "migrations"))
    command.upgrade(config, "0008")
    metadata = MetaData()
    users = Table("users", metadata, autoload_with=engine)
    measurements = Table("measurements", metadata, autoload_with=engine)
    now = time.time()
    with engine.begin() as db:
        db.execute(users.insert().values(id="legacy-owner", email="migration@example.test", password="fixture",
                                         failed_attempts=0, locked_until=now, role="member", active=1))
        # Initial SQL declares JSONB; SQLite reflection gives it numeric affinity.
        db.execute(text("INSERT INTO sessions (id,owner_id,title,family,expected,symptoms,supply_v,"
                        "diagnosis_mode,language,state,version,specification,spec_version,analysis_steps,"
                        "created_at,purpose) VALUES ('legacy-session','legacy-owner','Legacy fixture',"
                        "'voltage_divider','2.5 V','Synthetic fixture',5,'simulation','en','draft',1,"
                        "'{}',0,0,:now,'diagnosis')"), {"now": now})
        db.execute(measurements.insert().values(id="legacy-reading", session_id="legacy-session",
                    client_id="legacy-reading", point_id="TP1", value=2.5, unit="V", source="simulated",
                    phase="diagnosis", measured_at=now, created_at=now))
    command.upgrade(config, "head")
    metadata = MetaData()
    measurements = Table("measurements", metadata, autoload_with=engine)
    with engine.begin() as db:
        old = db.execute(select(measurements)).mappings().one()
        assert old["value"] == 2.5 and old["boolean_value"] is None and old["source"] == "simulated"
        db.execute(measurements.insert().values(id="boolean-reading", session_id="legacy-session",
                    client_id="boolean-reading", point_id="TP2", value=None, boolean_value=False,
                    unit="boolean", source="simulated", phase="diagnosis", measured_at=now, created_at=now))
        assert db.execute(select(measurements.c.boolean_value).where(
            measurements.c.id == "boolean-reading")).scalar_one() is False
    with pytest.raises(RuntimeError, match="destructive downgrade"):
        command.downgrade(config, "0008")
    with engine.connect() as db:
        assert set(db.scalars(select(measurements.c.id))) == {"legacy-reading", "boolean-reading"}
    engine.dispose()
