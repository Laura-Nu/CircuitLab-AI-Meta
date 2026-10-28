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
