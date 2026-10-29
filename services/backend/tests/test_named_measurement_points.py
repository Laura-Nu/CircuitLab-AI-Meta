"""Connection names/classifications do not change electrical authorization or measurement IDs."""
import pytest
from pydantic import ValidationError
from app.schemas import Point

P = "/api/v1"


def test_legacy_point_defaults_to_custom_without_changing_its_reference():
    point = Point(id="TP7", label="Sensor output", min_v=.2, max_v=2.8)
    assert point.kind == "custom" and point.id == "TP7"
    assert point.model_dump()["label"] == "Sensor output"


@pytest.mark.parametrize("kind", ["supply", "sensor_signal", "dc_output", "custom"])
def test_connection_type_does_not_assign_an_expected_voltage(kind):
    with pytest.raises(ValidationError):
        Point(id="TP1", label="Declared board connection", kind=kind)
    point = Point(id="TP1", label="Declared board connection", kind=kind, min_v=1, max_v=2)
    assert (point.min_v, point.max_v) == (1, 2)
    with pytest.raises(ValidationError):
        Point(id="TP1", label="Out of supported scope", kind=kind, min_v=0, max_v=12)


def test_unknown_connection_type_is_rejected():
    with pytest.raises(ValidationError):
        Point(id="TP1", label="Unsupported type", kind="automatic_pin", min_v=0, max_v=5)


def test_confirmed_name_and_type_persist_without_renumbering_the_point(client, headers, configured):
    sid = configured["id"]
    row = client.get(f"{P}/sessions/{sid}", headers=headers).json()
    spec = {**row["specification"], "version": row["version"], "confirmed": True}
    spec["points"] = [{"id": "TP7", "label": "Declared sensor terminal", "kind": "sensor_signal",
                       "min_v": .2, "max_v": 2.8}]
    result = client.patch(f"{P}/sessions/{sid}/specification", headers=headers, json=spec)
    assert result.status_code == 200
    stored = client.get(f"{P}/sessions/{sid}", headers=headers).json()["specification"]["points"][0]
    assert stored == {**spec["points"][0], "value_kind": "voltage"}
