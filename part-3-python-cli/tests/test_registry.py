"""Tests for the application registry."""

import os
import tempfile

import pytest

from appreg.models import AppConfig, ValidationError, validate_app_name, validate_environment
from appreg.registry import Registry


@pytest.fixture
def tmp_registry(tmp_path):
    return Registry(str(tmp_path))


class TestValidation:
    def test_valid_app_name(self):
        validate_app_name("my-service")
        validate_app_name("api-gateway")
        validate_app_name("service123")

    def test_invalid_app_name_empty(self):
        with pytest.raises(ValidationError, match="cannot be empty"):
            validate_app_name("")

    def test_invalid_app_name_uppercase(self):
        with pytest.raises(ValidationError, match="Invalid app name"):
            validate_app_name("MyService")

    def test_invalid_app_name_too_short(self):
        with pytest.raises(ValidationError, match="Invalid app name"):
            validate_app_name("ab")

    def test_invalid_app_name_starts_with_number(self):
        with pytest.raises(ValidationError, match="Invalid app name"):
            validate_app_name("1service")

    def test_valid_environments(self):
        for env in ("dev", "staging", "prod"):
            validate_environment(env)

    def test_invalid_environment(self):
        with pytest.raises(ValidationError, match="Invalid environment"):
            validate_environment("qa")


class TestAppConfig:
    def test_resolve_defaults_only(self):
        app = AppConfig(name="test-app", team="platform", defaults={"replicas": 2, "log_level": "info"})
        resolved = app.resolve("dev")
        assert resolved == {"replicas": 2, "log_level": "info"}

    def test_resolve_with_override(self):
        app = AppConfig(
            name="test-app",
            team="platform",
            defaults={"replicas": 2, "log_level": "info"},
            environments={"prod": {"replicas": 5, "log_level": "warn"}},
        )
        resolved = app.resolve("prod")
        assert resolved == {"replicas": 5, "log_level": "warn"}

    def test_resolve_partial_override(self):
        app = AppConfig(
            name="test-app",
            team="platform",
            defaults={"replicas": 2, "log_level": "info", "db_host": "localhost"},
            environments={"staging": {"db_host": "staging-db.internal"}},
        )
        resolved = app.resolve("staging")
        assert resolved == {"replicas": 2, "log_level": "info", "db_host": "staging-db.internal"}

    def test_resolve_invalid_environment(self):
        app = AppConfig(name="test-app", team="platform")
        with pytest.raises(ValidationError, match="Invalid environment"):
            app.resolve("unknown")

    def test_roundtrip_dict(self):
        app = AppConfig(
            name="test-app", team="platform", description="A test",
            defaults={"key": "val"}, environments={"dev": {"key": "override"}},
        )
        data = app.to_dict()
        restored = AppConfig.from_dict(data)
        assert restored.name == app.name
        assert restored.resolve("dev") == {"key": "override"}


class TestRegistry:
    def test_register_and_get(self, tmp_registry):
        app = tmp_registry.register("my-service", "platform", "Core API")
        assert app.name == "my-service"

        fetched = tmp_registry.get("my-service")
        assert fetched.team == "platform"
        assert fetched.description == "Core API"

    def test_register_duplicate(self, tmp_registry):
        tmp_registry.register("my-service", "platform")
        with pytest.raises(ValidationError, match="already exists"):
            tmp_registry.register("my-service", "platform")

    def test_get_nonexistent(self, tmp_registry):
        with pytest.raises(ValidationError, match="not found"):
            tmp_registry.get("nonexistent")

    def test_list_apps(self, tmp_registry):
        tmp_registry.register("alpha-svc", "team-a")
        tmp_registry.register("beta-svc", "team-b")
        apps = tmp_registry.list_apps()
        assert len(apps) == 2
        assert [a.name for a in apps] == ["alpha-svc", "beta-svc"]

    def test_set_default_config(self, tmp_registry):
        tmp_registry.register("my-service", "platform")
        tmp_registry.set_config("my-service", "replicas", "3")
        app = tmp_registry.get("my-service")
        assert app.defaults["replicas"] == 3

    def test_set_env_config(self, tmp_registry):
        tmp_registry.register("my-service", "platform")
        tmp_registry.set_config("my-service", "replicas", "5", env="prod")
        app = tmp_registry.get("my-service")
        assert app.environments["prod"]["replicas"] == 5

    def test_resolve_config(self, tmp_registry):
        tmp_registry.register("my-service", "platform")
        tmp_registry.set_config("my-service", "replicas", "2")
        tmp_registry.set_config("my-service", "log_level", "info")
        tmp_registry.set_config("my-service", "replicas", "5", env="prod")

        resolved = tmp_registry.resolve_config("my-service", "prod")
        assert resolved == {"replicas": 5, "log_level": "info"}

    def test_diff_envs(self, tmp_registry):
        tmp_registry.register("my-service", "platform")
        tmp_registry.set_config("my-service", "replicas", "2")
        tmp_registry.set_config("my-service", "log_level", "info")
        tmp_registry.set_config("my-service", "replicas", "5", env="prod")
        tmp_registry.set_config("my-service", "log_level", "debug", env="dev")

        diff = tmp_registry.diff_envs("my-service", "dev", "prod")
        assert "replicas" in diff
        assert diff["replicas"]["dev"] == 2
        assert diff["replicas"]["prod"] == 5
        assert diff["log_level"]["dev"] == "debug"
        assert diff["log_level"]["prod"] == "info"

    def test_unset_config(self, tmp_registry):
        tmp_registry.register("my-service", "platform")
        tmp_registry.set_config("my-service", "replicas", "2")
        tmp_registry.unset_config("my-service", "replicas")
        app = tmp_registry.get("my-service")
        assert "replicas" not in app.defaults

    def test_delete_app(self, tmp_registry):
        tmp_registry.register("my-service", "platform")
        tmp_registry.delete("my-service")
        with pytest.raises(ValidationError, match="not found"):
            tmp_registry.get("my-service")

    def test_value_coercion(self, tmp_registry):
        tmp_registry.register("my-service", "platform")
        tmp_registry.set_config("my-service", "replicas", "3")
        tmp_registry.set_config("my-service", "debug", "true")
        tmp_registry.set_config("my-service", "ratio", "0.5")
        tmp_registry.set_config("my-service", "host", "localhost")

        app = tmp_registry.get("my-service")
        assert app.defaults["replicas"] == 3
        assert app.defaults["debug"] is True
        assert app.defaults["ratio"] == 0.5
        assert app.defaults["host"] == "localhost"
