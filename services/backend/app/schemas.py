from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


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
    language: Literal["en", "es"] | None = None
    title: str = Field(min_length=3, max_length=120)
    family: Literal["led_resistor", "voltage_divider", "analog_sensor"]
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
    kind: Literal["supply", "sensor_signal", "dc_output", "custom"] = "custom"
    id: str = Field(pattern=r"^TP[1-9][0-9]?$", max_length=4)
    label: str = Field(min_length=1, max_length=120)
    min_v: float = Field(ge=0, le=5)
    max_v: float = Field(ge=0, le=5)

    @model_validator(mode="after")
    def bounds(self):
        if self.min_v > self.max_v:
            raise ValueError("min_v debe ser menor o igual a max_v")
        return self


class Specification(Strict):
    version: int = Field(ge=1)
    confirmed: Literal[True]
    connections: list[str] = Field(min_length=1, max_length=50)
    points: list[Point] = Field(min_length=1, max_length=8)
    functional_description: str = Field(min_length=5, max_length=1000)

    @model_validator(mode="after")
    def unique(self):
        if len({p.id for p in self.points}) != len(self.points):
            raise ValueError("Puntos duplicados")
        return self


class ManualMeasurement(Strict):
    client_id: str = Field(min_length=8, max_length=80)
    point_id: str = Field(max_length=4)
    value: float = Field(ge=0, le=5000)
    unit: Literal["V", "mV"] = "V"
    measured_at: float = Field(gt=0)
    conditions_confirmed: Literal[True]

    @model_validator(mode="after")
    def voltage_range(self):
        if self.unit == "V" and self.value > 5:
            raise ValueError("Máximo 5 V")
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
    action: Literal["read_voltage"] = "read_voltage"
    point_id: str
    sample_count: int = Field(default=20, ge=1, le=100)
    deadline_ms: int = Field(default=3000, ge=100, le=10000)


class HardwareResult(Strict):
    protocol_version: Literal["1"]
    command_id: str
    status: Literal["ok", "timeout", "disconnected", "out_of_range", "precondition_failed"]
    point_id: str
    value: float | None = Field(default=None, ge=0, le=5)
    unit: Literal["V"] = "V"
    sample_count: int = Field(ge=0, le=100)
    source: Literal["instrumented", "simulated"]
    calibration_id: str
    measured_at: float

    @model_validator(mode="after")
    def valid_reading(self):
        if self.status == "ok" and (self.value is None or self.sample_count == 0):
            raise ValueError("Una lectura correcta requiere valor y muestras")
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
        "request_connection_confirmation",
        "read_voltage",
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
