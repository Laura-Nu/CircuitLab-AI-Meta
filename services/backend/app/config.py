from functools import lru_cache
from typing import Literal
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field, SecretStr, model_validator


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    app_env: str = "development"
    app_origin: str = "http://localhost:8080"
    database_url: str = "sqlite:///./circuitlab.db"
    storage_root: str = "./data/evidence"
    meta_api_base_url: str = "https://api.meta.ai/v1"
    meta_api_key: SecretStr = SecretStr("")
    meta_reasoning_model: str = ""
    meta_provider: Literal["meta", "baseten", "self_hosted"] = "meta"
    meta_reasoning_effort: Literal["low", "medium", "high"] = "low"
    meta_timeout_seconds: int = Field(default=60, ge=5, le=90)
    storyboard_mode: Literal["disabled", "meta", "simulation"] = "disabled"
    storyboard_api_key: SecretStr = SecretStr("")
    storyboard_model: str = "muse-wonder-1.0"
    ai_mode: str = "meta"
    access_token_ttl_minutes: int = 30
    refresh_token_ttl_days: int = 7
    session_idle_minutes: int = Field(default=240, ge=240, le=1440)
    max_upload_mb: int = 10
    max_analysis_steps: int = 8
    worker_lease_seconds: int = 120
    hardware_command_timeout_seconds: int = 10
    recovery_delivery: Literal["disabled", "file", "resend"] = "disabled"
    recovery_directory: str = "./data/recovery"
    recovery_ttl_minutes: int = Field(default=20, ge=5, le=60)
    resend_api_key: SecretStr = SecretStr("")
    resend_from: str = ""

    @model_validator(mode="after")
    def inference_lease(self):
        if self.worker_lease_seconds <= self.meta_timeout_seconds + 15:
            raise ValueError("WORKER_LEASE_SECONDS must exceed META_TIMEOUT_SECONDS by more than 15 seconds")
        if self.storyboard_mode == "simulation" and self.app_env == "production":
            raise ValueError("Storyboard simulation is forbidden in production")
        return self


@lru_cache
def settings():
    return Settings()
