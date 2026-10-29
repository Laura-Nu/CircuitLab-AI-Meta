"""Versioned procedure catalog. Hardware cannot autonomously confirm these prerequisites."""

VOLTAGE_TEST = {
    "id": "dc_voltage_to_ground",
    "version": 1,
    "action": "read_voltage",
    "unit": "V",
    "range_v": [0, 5],
    "procedure": "Medir el punto confirmado respecto a GND común en la condición funcional registrada.",
    "preconditions": [
        "Referencia, impedancia y protección ADC verificadas",
        "GND común y punto instrumentado confirmados",
        "Alimentación dentro de 0–5 V",
    ],
    "manual_alternative": "request_manual_measurement",
    "sample_count": 20,
}


def localized_voltage_test(language):
    if language != "en":
        return {**VOLTAGE_TEST}
    return {
        **VOLTAGE_TEST,
        "procedure": "Measure the confirmed point relative to common GND under the recorded functional condition.",
        "preconditions": [
            "ADC reference, impedance and protection verified",
            "Common GND and instrumented point confirmed",
            "Supply voltage within 0–5 V",
        ],
    }

def localized_digital_test(language):
    return {
        "id": "digital_state_to_ground", "version": 1, "action": "read_digital",
        "unit": "boolean", "sample_count": 20,
        "procedure": (
            "Read the confirmed logic input under the declared test condition. All samples must agree."
            if language == "en" else
            "Lee la entrada lógica confirmada en la condición declarada. Todas las muestras deben coincidir."
        ),
        "preconditions": [
            "Logic-level compatibility, common GND and the instrument input are confirmed"
            if language == "en" else
            "Niveles lógicos compatibles, GND común y entrada del instrumento confirmados",
            "Firmware explicitly supports read_digital; do not infer a program variable from a photo or voltage"
            if language == "en" else
            "El firmware admite read_digital; no se infiere una variable del programa desde una foto o voltaje",
        ],
        "manual_alternative": "request_manual_measurement",
    }
