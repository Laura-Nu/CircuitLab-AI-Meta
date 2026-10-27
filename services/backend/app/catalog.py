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
