from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator, model_validator


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class Login(Strict):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=8, max_length=200)
    client: Literal["native", "web"] = "native"


class Refresh(Strict):
    refresh_token: str | None = Field(default=None, min_length=20, max_length=200)


class AccountEmail(Strict):
    email: str = Field(min_length=3, max_length=254)

    @field_validator("email")
    @classmethod
    def valid_email(cls, value):
        import re

        value = value.strip().lower()
        if not re.fullmatch(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+", value):
            raise ValueError("Invalid email")
        return value


class AccountRegister(AccountEmail):
    password: str = Field(min_length=12, max_length=200)
    client: Literal["native", "web"] = "native"


class AccountCreate(AccountEmail):
    password: str = Field(min_length=12, max_length=200)
    role: Literal["admin", "member"] = "member"


class AccountUpdate(Strict):
    role: Literal["admin", "member"]
    active: bool


class PasswordReset(Strict):
    token: str = Field(min_length=32, max_length=200)
    password: str = Field(min_length=12, max_length=200)


class SessionCreate(Strict):
    reference_session_id: str | None = Field(default=None, max_length=80)
    language: Literal["en", "es"] | None = None
    title: str = Field(min_length=3, max_length=120)
    family: Literal["led_resistor", "voltage_divider", "analog_sensor", "digital_signal", "microcontroller", "custom"]
    setup: str = Field(default="", max_length=2000)
    expected: str = Field(min_length=5, max_length=2000)
    purpose: Literal["diagnosis", "check_operation"] = "diagnosis"
    symptoms: str = Field(default="", max_length=2000)
    supply_v: float = Field(gt=0, le=5)

    @model_validator(mode="after")
    def symptoms_for_diagnosis(self):
        self.symptoms = self.symptoms.strip()
        if self.purpose == "diagnosis" and len(self.symptoms) < 5:
            raise ValueError("Diagnosis requires a description of the observed symptoms")
        return self


class Point(Strict):
    kind: Literal["supply", "sensor_signal", "dc_output", "digital_state", "reported_state", "numeric", "text", "custom"] = "custom"
    id: str = Field(pattern=r"^TP[1-9][0-9]?$", max_length=4)
    label: str = Field(min_length=1, max_length=120)
    value_kind: Literal["voltage", "boolean", "number", "text"] = "voltage"
    min_v: float | None = Field(default=None, ge=0, le=5)
    max_v: float | None = Field(default=None, ge=0, le=5)
    expected_state: StrictBool | None = None
    unit: str | None = Field(default=None, min_length=1, max_length=24, pattern=r"^[^\s\x00-\x1f][^\x00-\x1f]*$")
    min_value: float | None = None
    max_value: float | None = None
    expected_text: str | None = Field(default=None, min_length=1, max_length=500)

    @model_validator(mode="after")
    def bounds(self):
        if self.value_kind in {"number", "text"}:
            if self.min_v is not None or self.max_v is not None or self.expected_state is not None:
                raise ValueError("Sensor observations cannot use voltage or boolean criteria")
            if self.value_kind == "number":
                if (not self.unit or self.unit in {"V", "mV", "boolean", "text"}
                        or self.min_value is None or self.max_value is None
                        or self.min_value > self.max_value or self.expected_text is not None):
                    raise ValueError("Numeric observations require a unit and an ordered range")
            elif (not self.expected_text or not self.expected_text.strip() or self.min_value is not None
                  or self.max_value is not None or self.unit not in {None, "text"}):
                raise ValueError("Text observations require an exact expected text")
            if self.kind not in {"custom", "numeric", "text"}:
                raise ValueError("Sensor observation kind does not match its criteria")
            return self
        if any(v is not None for v in (self.unit, self.min_value, self.max_value, self.expected_text)):
            raise ValueError("Voltage and boolean points cannot contain sensor criteria")
        if self.value_kind == "boolean":
            if self.expected_state is None or self.min_v is not None or self.max_v is not None:
                raise ValueError("Boolean points require an expected state and no voltage limits")
        elif self.min_v is None or self.max_v is None or self.expected_state is not None:
            raise ValueError("Voltage points require both voltage limits and no boolean state")
        elif self.min_v > self.max_v:
            raise ValueError("min_v debe ser menor o igual a max_v")
        if self.kind in {"digital_state", "reported_state"} and self.value_kind != "boolean":
            raise ValueError("Digital state points require boolean observations")
        return self


class Specification(Strict):
    version: int = Field(ge=1)
    confirmed: Literal[True]
    connections: list[str] = Field(min_length=1, max_length=50)
    points: list[Point] = Field(min_length=1, max_length=32)
    functional_description: str = Field(min_length=5, max_length=2000)

    @model_validator(mode="after")
    def unique(self):
        if len({p.id for p in self.points}) != len(self.points):
            raise ValueError("Puntos duplicados")
        return self


class EvidenceRemoval(Strict):
    version: int = Field(ge=1)
    confirmed: Literal[True]


class ObservationValue(Strict):
    value: float | StrictBool | str
    unit: str = Field(default="V", min_length=1, max_length=24, pattern=r"^[^\s\x00-\x1f][^\x00-\x1f]*$")

    @model_validator(mode="before")
    @classmethod
    def typed_value(cls, data):
        if isinstance(data, dict):
            value, unit = data.get("value"), data.get("unit", "V")
            if (unit == "boolean") != (type(value) is bool):
                raise ValueError("Boolean observations require true/false and unit=boolean")
            if unit == "text":
                if not isinstance(value, str) or not value.strip() or len(value) > 500:
                    raise ValueError("Text observations require nonempty text up to 500 characters")
            elif unit != "boolean" and type(value) not in (int, float):
                raise ValueError("Numeric observations require a JSON number")
        return data

    @model_validator(mode="after")
    def voltage_range(self):
        if self.unit in {"V", "mV"} and not 0 <= self.value <= (5 if self.unit == "V" else 5000):
            raise ValueError("Voltage is outside the supported range")
        return self


class ManualMeasurement(ObservationValue):
    client_id: str = Field(min_length=8, max_length=80)
    point_id: str = Field(max_length=4)
    measured_at: float = Field(gt=0)
    conditions_confirmed: Literal[True]


class SerialTelemetry(ObservationValue):
    circuitlab: Literal[1]
    channel: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,79}$")
    unit: str = Field(min_length=1, max_length=24, pattern=r"^[^\s\x00-\x1f][^\x00-\x1f]*$")
    sensor: str | None = Field(default=None, min_length=1, max_length=80)
    board: str | None = Field(default=None, min_length=1, max_length=120)
    label: str | None = Field(default=None, min_length=1, max_length=120)

    @field_validator("value")
    @classmethod
    def clean_text_value(cls, value):
        if isinstance(value, str) and any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value):
            raise ValueError("Serial text values cannot contain control characters")
        return value

    @field_validator("unit", "sensor", "board", "label")
    @classmethod
    def clean_metadata(cls, value):
        if value is None or (not value.strip() or value != value.strip()
                             or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value)):
            raise ValueError("Serial metadata must be trimmed text without control characters")
        return value

    @field_validator("circuitlab", mode="before")
    @classmethod
    def exact_protocol(cls, value):
        if type(value) is not int or value != 1:
            raise ValueError("Unsupported serial telemetry protocol")
        return value


class SerialReading(Strict):
    client_id: str = Field(min_length=8, max_length=80)
    point_id: str = Field(pattern=r"^TP[1-9][0-9]?$", max_length=4)
    line: str = Field(min_length=1, max_length=500)
    received_at: float = Field(gt=0)
    conditions_confirmed: Literal[True]
    spec_version: int = Field(ge=1)
    request_version: int = Field(ge=1)


class SerialCapture(Strict):
    client_id: str = Field(min_length=8, max_length=80)
    baud_rate: Literal[9600, 19200, 38400, 57600, 115200]
    lines: list[str] = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def bounded_text(self):
        if any(not line.strip() or len(line) > 500 for line in self.lines):
            raise ValueError("Serial lines must contain 1–500 characters")
        if sum(len(line.encode("utf-8")) for line in self.lines) > 24000:
            raise ValueError("Serial capture is too large")
        return self


class AnalysisRequest(Strict):
    evidence_id: str | None = Field(default=None, max_length=80)


class DiagnosticContext(Strict):
    client_id: str = Field(min_length=8, max_length=80)
    kind: Literal["program", "problem"]
    content: str = Field(min_length=5, max_length=20000)
    point_id: str | None = Field(default=None, pattern=r"^TP[1-9][0-9]?$")

    @model_validator(mode="after")
    def meaningful_content(self):
        if len(self.content.strip()) < 5 or (self.kind == "problem" and len(self.content) > 2000):
            raise ValueError("Provide the actual program or a concise observed problem")
        return self


class InterventionCreate(Strict):
    description: str = Field(min_length=5, max_length=2000)
    confirmed: Literal[True]


class ConnectionConfirmation(Strict):
    description: str = Field(min_length=5, max_length=1000)
    confirmed: Literal[True]


class FunctionalCheck(Strict):
    client_id: str = Field(min_length=8, max_length=80)
    passed: bool
    observations: str = Field(min_length=5, max_length=2000)
    performed_at: float = Field(gt=0)
    confirmed: Literal[True]


class CloseSession(Strict):
    version: int = Field(ge=1)
    reason: str = Field(min_length=5, max_length=1000)
    confirmed: Literal[True]


class Enroll(Strict):
    transport: Literal["bridge", "browser_usb"] = "bridge"
    name: str = Field(min_length=2, max_length=120)
    points: list[str] = Field(min_length=1, max_length=8)
    calibration_id: str = Field(min_length=3, max_length=120)
    simulated: bool = False


class HardwareRequest(Strict):
    device_id: str
    point_id: str
    conditions_confirmed: Literal[True]


class HardwareCommand(Strict):
    protocol_version: Literal["1"] = "1"
    command_id: str
    session_id: str
    device_id: str
    action: Literal["read_voltage", "read_digital"] = "read_voltage"
    point_id: str
    sample_count: int = Field(default=20, ge=1, le=100)
    deadline_ms: int = Field(default=3000, ge=100, le=10000)


class HardwareResult(Strict):
    protocol_version: Literal["1"]
    command_id: str
    status: Literal["ok", "timeout", "disconnected", "out_of_range", "precondition_failed"]
    point_id: str
    value: float | StrictBool | None = None
    unit: Literal["V", "boolean"] = "V"
    sample_count: int = Field(ge=0, le=100)
    source: Literal["instrumented", "simulated"]
    calibration_id: str
    measured_at: float

    @model_validator(mode="before")
    @classmethod
    def typed_value(cls, data):
        if isinstance(data, dict) and data.get("value") is not None:
            if (data.get("unit", "V") == "boolean") != (type(data["value"]) is bool):
                raise ValueError("Boolean results require a JSON boolean and unit=boolean")
        return data

    @model_validator(mode="after")
    def valid_reading(self):
        if self.status == "ok" and (self.value is None or self.sample_count == 0):
            raise ValueError("Una lectura correcta requiere valor y muestras")
        if self.unit == "V" and self.value is not None and not 0 <= self.value <= 5:
            raise ValueError("Voltage is outside the supported range")
        if self.status != "ok" and self.value is not None:
            raise ValueError("Un error no es una lectura")
        return self


class BrowserUSBLease(Strict):
    lease: str = Field(min_length=32, max_length=128)


class BrowserUSBResult(BrowserUSBLease):
    result: HardwareResult


class HypothesisOutput(Strict):
    cause: str = Field(min_length=3, max_length=500)
    status: Literal["proposed", "compatible", "contradicted", "discarded", "supported_by_test"]
    evidence_ids: list[str] = Field(max_length=30)
    explanation: str = Field(max_length=1500)


class DiagnosisText(Strict):
    observations: list[str] = Field(max_length=20)
    causes: list[str] = Field(max_length=6)
    explanations: list[str] = Field(max_length=6)
    instruction: str = Field(min_length=5, max_length=2000)
    rationale: str = Field(min_length=5, max_length=2000)


class DiagnosisTranslations(Strict):
    en: DiagnosisText
    es: DiagnosisText


class BilingualText(Strict):
    en: str = Field(min_length=1, max_length=500)
    es: str = Field(min_length=1, max_length=500)

    @field_validator("en", "es")
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError("Text cannot be blank")
        return value.strip()


class TestPrediction(Strict):
    hypothesis_index: int = Field(ge=0, le=5)
    expected_outcome: BilingualText


class DiagnosisOutput(Strict):
    test_predictions: list[TestPrediction] = Field(default_factory=list, max_length=6)
    translations: DiagnosisTranslations | None = None
    observations: list[str] = Field(max_length=20)
    hypotheses: list[HypothesisOutput] = Field(max_length=6)
    action: Literal[
        "request_additional_view",
        "request_program",
        "request_connection_confirmation",
        "read_voltage",
        "read_digital",
        "request_manual_measurement",
        "propose_intervention",
        "inconclusive",
    ]
    point_id: str | None = Field(default=None, pattern=r"^TP[1-9][0-9]?$", max_length=4)
    instruction: str = Field(min_length=5, max_length=2000)
    rationale: str = Field(min_length=5, max_length=2000)

    @field_validator("point_id", mode="before")
    @classmethod
    def optional_point(cls, value):
        if isinstance(value, str):
            value = value.strip()
            if value.casefold() in {"", "null", "none", "undefined", "n/a"}:
                return None
        return value

    @model_validator(mode="after")
    def translation_alignment(self):
        indices = [p.hypothesis_index for p in self.test_predictions]
        if len(set(indices)) != len(indices) or any(i >= len(self.hypotheses) for i in indices):
            raise ValueError("Predictions must reference distinct existing hypotheses")
        if self.translations:
            for translated in (self.translations.en, self.translations.es):
                if len(translated.causes) != len(self.hypotheses) or len(translated.explanations) != len(
                    self.hypotheses
                ):
                    raise ValueError("Translation hypotheses must align with the original output")
        return self


class StoryFrame(Strict):
    headline: BilingualText
    caption: BilingualText
    source_ids: list[str] = Field(min_length=1, max_length=6)


class StoryOutput(Strict):
    title: BilingualText
    frames: list[StoryFrame] = Field(min_length=2, max_length=6)
