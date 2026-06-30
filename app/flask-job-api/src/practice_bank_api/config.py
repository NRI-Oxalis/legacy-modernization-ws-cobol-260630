import os
from dataclasses import dataclass


def _csv_env(name: str, default: str) -> tuple[str, ...]:
    raw_value = os.getenv(name, default)
    return tuple(item.strip() for item in raw_value.split(",") if item.strip())


@dataclass(frozen=True)
class Settings:
    subscription_id: str
    resource_group: str
    allowed_jobs: tuple[str, ...]
    api_version: str = "2024-03-01"

    @classmethod
    def from_env(cls) -> "Settings":
        default_job = os.getenv("AZURE_CONTAINERAPP_JOB_NAME", "pb-batch")
        return cls(
            subscription_id=os.environ["AZURE_SUBSCRIPTION_ID"],
            resource_group=os.getenv("AZURE_RESOURCE_GROUP", "rg-practicebank"),
            allowed_jobs=_csv_env("AZURE_CONTAINERAPP_ALLOWED_JOBS", default_job),
            api_version=os.getenv("AZURE_CONTAINERAPP_API_VERSION", "2024-03-01"),
        )


class ConfigError(RuntimeError):
    pass