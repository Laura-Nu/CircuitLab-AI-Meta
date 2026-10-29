import pytest
from sqlalchemy import select
from app.db import ModelRun, User

P = "/api/v1"


@pytest.mark.parametrize("language", ["en", "es"])
def test_readable_report_uses_viewer_role_for_model_details(
    client, database, headers, configured, language
):
    sid = configured["id"]
    with database() as db:
        db.add(ModelRun(session_id=sid, data={
            "provider": "unit-test-provider",
            "model": "unit-test-model",
            "response_model": "unit-test-reported-model",
            "request_id": "unit-test-request",
            "output": {
                "observations": ["Known report observation"],
                "instruction": "Known proposed measurement",
                "test_predictions": [{
                    "hypothesis_index": 0,
                    "expected_outcome": {
                        "en": "Known expected low input",
                        "es": "Entrada baja prevista",
                    },
                }],
            },
        }))
        db.commit()
    auth = {**headers, "Accept-Language": language}
    url = f"{P}/sessions/{sid}/report?format=markdown"
    member = client.get(url, headers=auth)
    assert member.status_code == 200
    assert "Known report observation" in member.text
    assert "Known proposed measurement" in member.text
    assert ("Known expected low input" if language == "en" else "Entrada baja prevista") in member.text
    for value in ("unit-test-provider", "unit-test-model",
                  "unit-test-reported-model", "unit-test-request"):
        assert value not in member.text
    with database() as db:
        owner = db.scalar(select(User).where(User.email == "owner@example.test"))
        owner.role = "admin"
        db.commit()
    administrator = client.get(url, headers=auth)
    assert administrator.status_code == 200
    assert "Known report observation" in administrator.text
    assert "unit-test-provider" in administrator.text
    assert "unit-test-model" in administrator.text
    assert "unit-test-request" in administrator.text


@pytest.mark.parametrize("language", ["en", "es"])
def test_report_numbers_remove_padding_without_rounding_measurements(
    client, database, headers, configured, language
):
    import time
    from app.db import Measurement

    sid = configured["id"]
    with database() as db:
        for index, value in enumerate([5.0, 2.5, 0.0004]):
            db.add(Measurement(
                session_id=sid, client_id=f"synthetic-number-format-{index}",
                point_id="TP1", value=value, unit="V", source="simulated",
                phase="diagnosis", measured_at=time.time(),
            ))
        db.commit()
    response = client.get(
        f"{P}/sessions/{sid}/report?format=markdown",
        headers={**headers, "Accept-Language": language},
    )
    assert response.status_code == 200
    assert "TP1: 5 V" in response.text
    assert ("TP1: 2,5 V" if language == "es" else "TP1: 2.5 V") in response.text
    assert ("TP1: 0,0004 V" if language == "es" else "TP1: 0.0004 V") in response.text
    assert "5.000 V" not in response.text
