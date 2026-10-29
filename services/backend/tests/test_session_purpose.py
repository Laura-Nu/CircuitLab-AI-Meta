"""Operation-assessment regressions; fixtures do not represent physical acquisition."""
import time
from sqlalchemy import select
from app.db import Event, Measurement, Session
from app.schemas import SessionCreate
from app.worker import snapshot
import pytest

P = "/api/v1"
BODY = {"title": "Operation assessment", "family": "voltage_divider",
        "expected": "Stable half-input output", "supply_v": 5}


def test_symptoms_are_required_only_for_fault_diagnosis(client, headers):
    for symptoms in (None, "", "   ", "low"):
        data = {**BODY, **({"symptoms": symptoms} if symptoms is not None else {})}
        assert client.post(P + "/sessions", headers=headers, json=data).status_code == 422
    legacy = SessionCreate(**BODY, symptoms="Output lower than expected")
    assert legacy.purpose == "diagnosis"
    response = client.post(P + "/sessions", headers=headers,
                           json={**BODY, "purpose": "check_operation"})
    assert response.status_code == 201
    assert response.json()["symptoms"] == "" and response.json()["purpose"] == "check_operation"
    assert client.post(P + "/sessions", headers=headers,
                       json={**BODY, "purpose": "unknown"}).status_code == 422


def test_operation_purpose_reaches_the_audit_and_model_context(client, headers, database):
    row = client.post(P + "/sessions", headers=headers,
                      json={**BODY, "purpose": "check_operation", "symptoms": "  "}).json()
    with database() as db:
        session = db.get(Session, row["id"])
        assert snapshot(db, session)["purpose"] == "check_operation"
        event = db.scalar(select(Event).where(Event.session_id == session.id, Event.kind == "session_created"))
        assert event.data["purpose"] == "check_operation"


@pytest.mark.parametrize("passed", [True, False])
def test_operation_finishes_only_after_readings_and_a_functional_observation(client, headers, database, passed):
    row = client.post(P + "/sessions", headers=headers,
                      json={**BODY, "purpose": "check_operation"}).json()
    path = P + "/sessions/" + row["id"]
    spec = {"version": row["version"], "confirmed": True, "connections": ["UNIT FIXTURE: declared unloaded divider"],
            "functional_description": "UNIT FIXTURE: stable output under stated conditions",
            "points": [{"id": "TP1", "label": "Output", "min_v": 2.35, "max_v": 2.65},
                       {"id": "TP2", "label": "Input", "min_v": 4.85, "max_v": 5}]}
    assert client.patch(path + "/specification", headers=headers, json=spec).status_code == 200
    # These explicitly simulated values are never sent to a hosted deployment as manual readings.
    with database() as db:
        session = db.get(Session, row["id"])
        session.analysis_steps = 1
        session.state = "inconclusive"
        for point, value in [("TP1", 2.5), ("TP2", 5)]:
            db.add(Measurement(session_id=session.id, client_id="unit-" + point, point_id=point,
                               value=value, unit="V", source="simulated", phase="diagnosis", measured_at=time.time()))
        db.commit()
    assert client.get(path, headers=headers).json()["completion"]["baseline_available"] is True
    assert client.post(path + "/baseline-check", headers=headers, json={
        "client_id": "unit-baseline-check", "passed": passed,
        "observations": "SIMULATED UNIT FIXTURE: no physical observation",
        "performed_at": time.time(), "confirmed": True,
    }).status_code == 201
    result = client.get(path, headers=headers).json()
    assert result["state"] == ("no_fault_found" if passed else "inconclusive")
    assert result["interventions"] == []
    assert result["verifications"][-1]["data"]["physical_verification"] is False
    report = client.get(path + "/report?format=markdown", headers={**headers, "Accept-Language": "en"})
    assert "Check operation" in report.text and "No symptoms reported." in report.text


def test_simulated_guide_requests_a_missing_point_instead_of_inventing_a_fault():
    from app.meta import demo_analysis
    result, audit = demo_analysis({
        "purpose": "check_operation", "language": "en",
        "specification": {"points": [{"id": "TP1", "min_v": 2.35, "max_v": 2.65},
                                    {"id": "TP2", "min_v": 4.85, "max_v": 5}]},
        "measurements": [{"id": "fixture-1", "point_id": "TP1", "value": 2.5, "source": "simulated"}],
    })
    assert result.point_id == "TP2" and result.action == "request_manual_measurement"
    assert audit["provider"] == "simulation"
