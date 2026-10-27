"""Public inputs and evaluator-only records are deliberately separate contracts."""

from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, model_validator

METHODS = ["initial_only", "free_questions", "fixed_tests", "structured"]
PROMPT_VERSION = "evaluation-1"


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class Point(Strict):
    id: str = Field(pattern=r"^TP[1-3]$")
    label: str
    min_v: float = Field(ge=0, le=5)
    max_v: float = Field(ge=0, le=5)

    @model_validator(mode="after")
    def bounds(self):
        if self.min_v > self.max_v:
            raise ValueError("Invalid point range")
        return self


class Picture(Strict):
    id: str
    file: str
    mime: Literal["image/jpeg", "image/png"]


class PublicCase(Strict):
    case_id: str
    mount_id: str
    split: Literal["development", "evaluation"]
    family: Literal["led_resistor", "voltage_divider", "analog_sensor"]
    language: Literal["en", "es"] = "en"
    expected: str
    symptoms: str
    connections: list[str]
    connections_confirmed: bool
    scope_confirmed: bool
    points: list[Point] = Field(min_length=1, max_length=3)
    diagnosis_catalog: list[str] = Field(min_length=1)
    questions: dict[str, str] = Field(default_factory=dict)
    evidence: list[Picture] = Field(default_factory=list, max_length=12)

    @model_validator(mode="after")
    def unique(self):
        if len({p.id for p in self.points}) != len(self.points):
            raise ValueError("Duplicate point")
        if len({e.id for e in self.evidence}) != len(self.evidence):
            raise ValueError("Duplicate evidence identifier")
        return self


class Reading(Strict):
    id: str
    point_id: str = Field(pattern=r"^TP[1-3]$")
    value: float | None = Field(default=None, ge=0, le=5)
    unit: Literal["V"] = "V"
    status: Literal["ok", "timeout", "disconnected", "out_of_range"] = "ok"
    source: Literal["simulated", "instrumented", "manual"]
    measured_at: float = Field(gt=0)
    calibration_id: str

    @model_validator(mode="after")
    def result(self):
        if (self.status == "ok") != (self.value is not None):
            raise ValueError("Only successful acquisitions contain a voltage")
        return self


class Observation(Strict):
    readings: dict[str, Reading]
    answers: dict[str, str] = Field(default_factory=dict)


class ObservationSet(Strict):
    provenance: Literal["simulation", "physical_replay"]
    hardware_version: str
    firmware_version: str
    catalog_version: str
    cases: dict[str, Observation]


class Label(Strict):
    kind: Literal["fault", "healthy", "ambiguous", "out_of_scope"]
    accepted_diagnoses: list[str]
    # Only an evaluator can supply these; they never reach the model or measurement oracle.
    intervention_confirmed_at: float | None = None
    intervention_for: str | None = None
    post_readings: list[Reading] = Field(default_factory=list)

    @model_validator(mode="after")
    def outcome(self):
        if bool(self.accepted_diagnoses) != (self.kind in {"fault", "healthy"}):
            raise ValueError("Fault/healthy cases require accepted codes; abstention cases have none")
        if len({r.id for r in self.post_readings}) != len(self.post_readings):
            raise ValueError("Duplicate verification reading identifier")
        return self


class Step(Strict):
    action: Literal["measure", "ask", "diagnose", "abstain"]
    target: str | None = None
    diagnosis: str | None = None
    hypotheses: list[str] = Field(default_factory=list, max_length=6)
    evidence_ids: list[str] = Field(default_factory=list, max_length=30)
    rationale: str = Field(min_length=1, max_length=2000)
    claims_repair: bool = False

    @model_validator(mode="after")
    def action_fields(self):
        if (self.action == "diagnose") != (self.diagnosis is not None):
            raise ValueError("Only a final diagnosis contains a diagnosis code")
        if (self.action in {"measure", "ask"}) != (self.target is not None):
            raise ValueError("Only queries contain a target")
        return self


class Plan(Strict):
    version: str
    seed: int
    methods: list[Literal["initial_only", "free_questions", "fixed_tests", "structured"]]
    repetitions: int = Field(ge=1, le=20)
    max_model_calls: int = Field(ge=1, le=8)
    max_queries: int = Field(ge=0, le=6)
    max_tokens_per_call: int = Field(ge=100, le=2500)
    fixed_order: list[str]
    input_usd_per_million: float | None = Field(default=None, ge=0)
    output_usd_per_million: float | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def valid(self):
        if set(self.methods) != set(METHODS) or len(self.methods) != 4:
            raise ValueError("Register all four methods exactly once")
        if len(self.fixed_order) != len(set(self.fixed_order)):
            raise ValueError("Duplicate fixed-order point")
        if self.max_model_calls <= self.max_queries:
            raise ValueError("Reserve a model call for the final decision")
        return self
