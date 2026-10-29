"""Typed observations: a boolean state is never a voltage or an implicit threshold."""
def point_is_boolean(point):
    return point.get("value_kind", "voltage") == "boolean"


def reading_value(reading):
    if isinstance(reading, dict):
        return reading.get("value")
    return reading.boolean_value if reading.unit == "boolean" else reading.value


def point_unit(point):
    return "boolean" if point_is_boolean(point) else "V"


def reading_passes(point, reading):
    if reading is None:
        return False
    unit = reading.get("unit", "V") if isinstance(reading, dict) else reading.unit
    if unit != point_unit(point):
        return False
    value = reading_value(reading)
    if point_is_boolean(point):
        return type(value) is bool and value is point["expected_state"]
    return type(value) in (int, float) and point["min_v"] <= value <= point["max_v"]


def point_check(point, reading):
    return {
        "point_id": point["id"], "label": point["label"],
        "value_kind": point.get("value_kind", "voltage"), "unit": point_unit(point),
        "min_v": point.get("min_v"), "max_v": point.get("max_v"),
        "expected_state": point.get("expected_state"),
        "measurement_id": reading.id if reading else None,
        "value": reading_value(reading) if reading else None,
        "source": reading.source if reading else None,
        "measured_at": reading.measured_at if reading else None,
        "passed": reading_passes(point, reading),
    }


def observation_fields(value, unit):
    return {"value": None, "boolean_value": value, "unit": "boolean"} if unit == "boolean" else {
        "value": value, "boolean_value": None, "unit": "V",
    }
