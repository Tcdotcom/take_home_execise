"""Data models and validation for the application registry."""

import re
from dataclasses import dataclass, field
from typing import Any, Dict, Optional

VALID_ENVIRONMENTS = {"dev", "staging", "prod"}
APP_NAME_PATTERN = re.compile(r"^[a-z][a-z0-9-]{1,62}[a-z0-9]$")


class ValidationError(Exception):
    """Raised when input validation fails."""


@dataclass
class AppConfig:
    """Represents a registered application and its configuration."""

    name: str
    team: str
    description: str = ""
    defaults: Dict[str, Any] = field(default_factory=dict)
    environments: Dict[str, Dict[str, Any]] = field(default_factory=dict)

    def resolve(self, env: str) -> Dict[str, Any]:
        """Merge defaults with environment-specific overrides.

        Resolution order: defaults <- env overrides
        """
        validate_environment(env)
        resolved = dict(self.defaults)
        if env in self.environments:
            resolved.update(self.environments[env])
        return resolved

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "team": self.team,
            "description": self.description,
            "defaults": self.defaults,
            "environments": self.environments,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "AppConfig":
        validate_app_name(data.get("name", ""))
        return cls(
            name=data["name"],
            team=data.get("team", ""),
            description=data.get("description", ""),
            defaults=data.get("defaults", {}),
            environments=data.get("environments", {}),
        )


def validate_app_name(name: str) -> None:
    if not name:
        raise ValidationError("Application name cannot be empty.")
    if not APP_NAME_PATTERN.match(name):
        raise ValidationError(
            f"Invalid app name '{name}'. Must be 3-64 lowercase alphanumeric "
            "characters or hyphens, starting with a letter."
        )


def validate_environment(env: str) -> None:
    if env not in VALID_ENVIRONMENTS:
        raise ValidationError(
            f"Invalid environment '{env}'. Must be one of: {', '.join(sorted(VALID_ENVIRONMENTS))}"
        )


def validate_config_key(key: str) -> None:
    if not key:
        raise ValidationError("Configuration key cannot be empty.")
    if not re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*$", key):
        raise ValidationError(
            f"Invalid config key '{key}'. Use alphanumeric characters and underscores."
        )
