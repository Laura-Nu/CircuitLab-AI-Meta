"""Regression: the production inspector must accept this image's migrations, not a stale constant.

All databases and credentials below are isolated fixtures; no provider or deployment is contacted.
"""
from pathlib import Path
from alembic.script import ScriptDirectory
import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from app import production_check
from app.db import Base


@pytest.mark.parametrize("state,passed", [
    ("current", True), ("stale", False), ("unversioned", False),
    ("unknown", False), ("extra_head", False),
])
def test_production_inspector_compares_the_entire_shipped_head_set(tmp_path, monkeypatch, state, passed):
    engine = create_engine("sqlite:///" + (tmp_path / "inspection.sqlite3").as_posix())
    factory = sessionmaker(engine)
    Base.metadata.create_all(engine)
    shipped = set(ScriptDirectory(str(Path(__file__).resolve().parents[1] / "migrations")).get_heads())
    assert shipped and "0006" not in shipped
    heads = shipped if state in {"current", "extra_head"} else {"0006"} if state == "stale" else {"unknown"}
    if state == "extra_head":
        heads = heads | {"0006"}
    with factory() as db:
        if state != "unversioned":
            db.execute(text("CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY)"))
            for head in heads:
                db.execute(text("INSERT INTO alembic_version (version_num) VALUES (:head)"), {"head": head})
            db.commit()
        before = set(db.execute(text(
            "SELECT version_num FROM alembic_version")).scalars()) if state != "unversioned" else None
        assert production_check.migration_current(db) is passed
        if before is not None:
            assert set(db.execute(text("SELECT version_num FROM alembic_version")).scalars()) == before
    monkeypatch.setattr(production_check, "SessionLocal", factory)
    report = production_check.inspect_environment()
    assert report["checks"]["migration_current"] is passed
    engine.dispose()
