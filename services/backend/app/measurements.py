"""Typed observations: a boolean state is never a voltage or an implicit threshold."""
def point_is_boolean(point):
    return point.get("value_kind", "voltage") == "boolean"


def reading_value(reading):
    if isinstance(reading, dict):
        return reading.get("value")
    return (reading.boolean_value if reading.unit == "boolean" else
            reading.text_value if reading.unit == "text" else reading.value)


def point_unit(point):
    return {"boolean": "boolean", "text": "text", "number": point.get("unit")}.get(point.get("value_kind"), "V")


def reading_passes(point, reading):
    if reading is None:
        return False
    unit = reading.get("unit", "V") if isinstance(reading, dict) else reading.unit
    if unit != point_unit(point):
        return False
    value = reading_value(reading)
    if point_is_boolean(point):
        return type(value) is bool and value is point["expected_state"]
    if point.get("value_kind") == "text":
        return type(value) is str and value == point["expected_text"]
    if point.get("value_kind") == "number":
        return type(value) in (int, float) and point["min_value"] <= value <= point["max_value"]
    return type(value) in (int, float) and point["min_v"] <= value <= point["max_v"]


def point_check(point, reading):
    return {
        "point_id": point["id"], "label": point["label"],
        "value_kind": point.get("value_kind", "voltage"), "unit": point_unit(point),
        "min_v": point.get("min_v"), "max_v": point.get("max_v"),
        "expected_state": point.get("expected_state"),
        "min_value": point.get("min_value"), "max_value": point.get("max_value"),
        "expected_text": point.get("expected_text"),
        "measurement_id": reading.id if reading else None,
        "value": reading_value(reading) if reading else None,
        "source": reading.source if reading else None,
        "measured_at": reading.measured_at if reading else None,
        "passed": reading_passes(point, reading),
    }


def observation_fields(value, unit):
    return {
        "value": value if unit not in {"boolean", "text"} else None,
        "boolean_value": value if unit == "boolean" else None,
        "text_value": value if unit == "text" else None,
        "unit": "V" if unit == "mV" else unit,
    }
