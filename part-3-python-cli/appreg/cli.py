"""CLI interface for the application registry."""

import json
import sys

import click
import yaml

from .models import ValidationError
from .registry import Registry


def get_registry(ctx: click.Context) -> Registry:
    return ctx.obj["registry"]


@click.group()
@click.option(
    "--registry-dir", "-d",
    envvar="APPREG_REGISTRY_DIR",
    default="./registry",
    help="Path to registry data directory.",
)
@click.pass_context
def cli(ctx, registry_dir):
    """appreg — Application registry with environment-specific configuration overrides."""
    ctx.ensure_object(dict)
    ctx.obj["registry"] = Registry(registry_dir)


# ── register ──────────────────────────────────────────────────────────

@cli.command()
@click.argument("name")
@click.option("--team", "-t", required=True, help="Owning team name.")
@click.option("--description", "-D", default="", help="Short description.")
@click.pass_context
def register(ctx, name, team, description):
    """Register a new application."""
    try:
        reg = get_registry(ctx)
        app = reg.register(name, team, description)
        click.echo(f"Registered application '{app.name}' (team: {app.team})")
    except ValidationError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


# ── list ──────────────────────────────────────────────────────────────

@cli.command("list")
@click.pass_context
def list_apps(ctx):
    """List all registered applications."""
    reg = get_registry(ctx)
    apps = reg.list_apps()
    if not apps:
        click.echo("No applications registered.")
        return

    click.echo(f"{'NAME':<25} {'TEAM':<15} {'DESCRIPTION'}")
    click.echo("-" * 65)
    for app in apps:
        click.echo(f"{app.name:<25} {app.team:<15} {app.description}")


# ── config group ──────────────────────────────────────────────────────

@cli.group()
def config():
    """Manage application configuration."""
    pass


@config.command("set")
@click.argument("app_name")
@click.option("--key", "-k", required=True, help="Configuration key.")
@click.option("--value", "-v", required=True, help="Configuration value.")
@click.option("--env", "-e", default=None, help="Target environment (omit for default).")
@click.pass_context
def config_set(ctx, app_name, key, value, env):
    """Set a configuration value (default or environment override)."""
    try:
        reg = get_registry(ctx)
        reg.set_config(app_name, key, value, env)
        target = f"environment '{env}'" if env else "defaults"
        click.echo(f"Set {app_name}.{key} = {value} in {target}")
    except ValidationError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@config.command("unset")
@click.argument("app_name")
@click.option("--key", "-k", required=True, help="Configuration key to remove.")
@click.option("--env", "-e", default=None, help="Target environment (omit for default).")
@click.pass_context
def config_unset(ctx, app_name, key, env):
    """Remove a configuration value."""
    try:
        reg = get_registry(ctx)
        reg.unset_config(app_name, key, env)
        target = f"environment '{env}'" if env else "defaults"
        click.echo(f"Removed {app_name}.{key} from {target}")
    except ValidationError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@config.command("get")
@click.argument("app_name")
@click.option("--env", "-e", required=True, help="Environment to resolve.")
@click.option("--format", "fmt", type=click.Choice(["table", "yaml", "json"]), default="table", help="Output format.")
@click.pass_context
def config_get(ctx, app_name, env, fmt):
    """Show resolved configuration for an environment."""
    try:
        reg = get_registry(ctx)
        resolved = reg.resolve_config(app_name, env)

        if not resolved:
            click.echo(f"No configuration for '{app_name}' in '{env}'.")
            return

        if fmt == "yaml":
            click.echo(yaml.dump(resolved, default_flow_style=False).rstrip())
        elif fmt == "json":
            click.echo(json.dumps(resolved, indent=2))
        else:
            click.echo(f"Resolved config for '{app_name}' in '{env}':")
            click.echo("-" * 40)
            for k, v in sorted(resolved.items()):
                click.echo(f"  {k}: {v}")
    except ValidationError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@config.command("diff")
@click.argument("app_name")
@click.option("--env1", required=True, help="First environment.")
@click.option("--env2", required=True, help="Second environment.")
@click.pass_context
def config_diff(ctx, app_name, env1, env2):
    """Show configuration differences between two environments."""
    try:
        reg = get_registry(ctx)
        diff = reg.diff_envs(app_name, env1, env2)

        if not diff:
            click.echo(f"No differences between '{env1}' and '{env2}'.")
            return

        click.echo(f"Config diff for '{app_name}': {env1} vs {env2}")
        click.echo("-" * 50)
        click.echo(f"  {'KEY':<20} {env1:<15} {env2:<15}")
        click.echo(f"  {'---':<20} {'---':<15} {'---':<15}")
        for key, vals in sorted(diff.items()):
            v1 = vals.get(env1, "<unset>")
            v2 = vals.get(env2, "<unset>")
            click.echo(f"  {key:<20} {str(v1):<15} {str(v2):<15}")
    except ValidationError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


# ── export ────────────────────────────────────────────────────────────

@cli.command()
@click.argument("app_name")
@click.option("--env", "-e", required=True, help="Environment to resolve.")
@click.option("--format", "fmt", type=click.Choice(["yaml", "json"]), default="yaml", help="Output format.")
@click.pass_context
def export(ctx, app_name, env, fmt):
    """Export resolved configuration for an environment."""
    try:
        reg = get_registry(ctx)
        resolved = reg.resolve_config(app_name, env)

        output = {
            "app": app_name,
            "environment": env,
            "config": resolved,
        }

        if fmt == "yaml":
            click.echo(yaml.dump(output, default_flow_style=False).rstrip())
        else:
            click.echo(json.dumps(output, indent=2))
    except ValidationError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


# ── delete ────────────────────────────────────────────────────────────

@cli.command()
@click.argument("app_name")
@click.confirmation_option(prompt="Are you sure you want to delete this application?")
@click.pass_context
def delete(ctx, app_name):
    """Delete a registered application."""
    try:
        reg = get_registry(ctx)
        reg.delete(app_name)
        click.echo(f"Deleted application '{app_name}'.")
    except ValidationError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


if __name__ == "__main__":
    cli()
