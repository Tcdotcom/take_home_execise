"""Registry storage and operations — YAML-backed application registry."""

import os
from pathlib import Path
from typing import Dict, List, Optional

import yaml

from .models import AppConfig, ValidationError, validate_app_name, validate_config_key, validate_environment

DEFAULT_REGISTRY_DIR = os.environ.get("APPREG_REGISTRY_DIR", "./registry")


class Registry:
    """File-backed application registry using YAML storage."""

    def __init__(self, registry_dir: Optional[str] = None):
        self.registry_dir = Path(registry_dir or DEFAULT_REGISTRY_DIR)
        self.registry_dir.mkdir(parents=True, exist_ok=True)

    def _app_path(self, name: str) -> Path:
        return self.registry_dir / f"{name}.yaml"

    def register(self, name: str, team: str, description: str = "") -> AppConfig:
        validate_app_name(name)
        path = self._app_path(name)
        if path.exists():
            raise ValidationError(f"Application '{name}' already exists.")

        app = AppConfig(name=name, team=team, description=description)
        self._save(app)
        return app

    def get(self, name: str) -> AppConfig:
        validate_app_name(name)
        path = self._app_path(name)
        if not path.exists():
            raise ValidationError(f"Application '{name}' not found.")

        with open(path) as f:
            data = yaml.safe_load(f)
        return AppConfig.from_dict(data)

    def list_apps(self) -> List[AppConfig]:
        apps = []
        for path in sorted(self.registry_dir.glob("*.yaml")):
            with open(path) as f:
                data = yaml.safe_load(f)
            if data:
                apps.append(AppConfig.from_dict(data))
        return apps

    def set_config(self, name: str, key: str, value: str, env: Optional[str] = None) -> None:
        validate_config_key(key)
        app = self.get(name)

        # Auto-coerce values
        coerced = self._coerce_value(value)

        if env:
            validate_environment(env)
            if env not in app.environments:
                app.environments[env] = {}
            app.environments[env][key] = coerced
        else:
            app.defaults[key] = coerced

        self._save(app)

    def unset_config(self, name: str, key: str, env: Optional[str] = None) -> None:
        validate_config_key(key)
        app = self.get(name)

        if env:
            validate_environment(env)
            if env in app.environments and key in app.environments[env]:
                del app.environments[env][key]
            else:
                raise ValidationError(f"Key '{key}' not found in environment '{env}'.")
        else:
            if key in app.defaults:
                del app.defaults[key]
            else:
                raise ValidationError(f"Key '{key}' not found in defaults.")

        self._save(app)

    def resolve_config(self, name: str, env: str) -> Dict:
        app = self.get(name)
        return app.resolve(env)

    def diff_envs(self, name: str, env1: str, env2: str) -> Dict:
        resolved1 = self.resolve_config(name, env1)
        resolved2 = self.resolve_config(name, env2)

        all_keys = sorted(set(resolved1.keys()) | set(resolved2.keys()))
        diff = {}
        for key in all_keys:
            v1 = resolved1.get(key)
            v2 = resolved2.get(key)
            if v1 != v2:
                diff[key] = {env1: v1, env2: v2}
        return diff

    def delete(self, name: str) -> None:
        validate_app_name(name)
        path = self._app_path(name)
        if not path.exists():
            raise ValidationError(f"Application '{name}' not found.")
        path.unlink()

    def _save(self, app: AppConfig) -> None:
        path = self._app_path(app.name)
        with open(path, "w") as f:
            yaml.dump(app.to_dict(), f, default_flow_style=False, sort_keys=False)

    @staticmethod
    def _coerce_value(value: str):
        """Coerce string values to appropriate Python types."""
        if value.lower() in ("true", "false"):
            return value.lower() == "true"
        try:
            return int(value)
        except ValueError:
            pass
        try:
            return float(value)
        except ValueError:
            pass
        return value
