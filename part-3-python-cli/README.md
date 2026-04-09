# Part 3 — Python CLI: Application Registry and Environment Overrides

## Overview

`appreg` is a CLI tool for managing an application registry with environment-specific configuration overrides. Engineers register applications, set default configuration values, apply per-environment overrides, and inspect resolved configuration predictably.

## Design Choices

- **Click** for CLI framework — mature, composable, excellent help generation
- **YAML storage** — one file per app in `./registry/`, human-readable and Git-friendly
- **Separation of concerns** — `models.py` (validation + data), `registry.py` (storage + operations), `cli.py` (user interface)
- **Value coercion** — string inputs auto-coerced to `int`, `float`, or `bool` where applicable
- **Resolution logic** — simple `defaults | env_overrides` merge. Overrides win. No deep merge by design (flat config keys are more predictable)

## Setup

```bash
cd part-3-python-cli

# Install dependencies
pip install click pyyaml pytest

# Run directly
python -m appreg.cli --help

# Or install as a package
pip install -e .
appreg --help
```

## Usage

### Register an application

```bash
$ appreg register payment-service --team payments --description "Handles payment processing"
Registered application 'payment-service' (team: payments)
```

### Set default configuration

```bash
$ appreg config set payment-service --key replicas --value 2
Set payment-service.replicas = 2 in defaults

$ appreg config set payment-service --key log_level --value info
Set payment-service.log_level = info in defaults

$ appreg config set payment-service --key db_host --value localhost
Set payment-service.db_host = localhost in defaults
```

### Set environment overrides

```bash
$ appreg config set payment-service --key replicas --value 5 --env prod
Set payment-service.replicas = 5 in environment 'prod'

$ appreg config set payment-service --key log_level --value debug --env dev
Set payment-service.log_level = debug in environment 'dev'

$ appreg config set payment-service --key db_host --value prod-db.internal --env prod
Set payment-service.db_host = prod-db.internal in environment 'prod'
```

### View resolved configuration

```bash
$ appreg config get payment-service --env prod
Resolved config for 'payment-service' in 'prod':
----------------------------------------
  db_host: prod-db.internal
  log_level: info
  replicas: 5

$ appreg config get payment-service --env prod --format yaml
db_host: prod-db.internal
log_level: info
replicas: 5
```

### Compare environments

```bash
$ appreg config diff payment-service --env1 dev --env2 prod
Config diff for 'payment-service': dev vs prod
--------------------------------------------------
  KEY                  dev             prod
  ---                  ---             ---
  db_host              localhost        prod-db.internal
  log_level            debug            info
  replicas             2                5
```

### List applications

```bash
$ appreg list
NAME                      TEAM            DESCRIPTION
-----------------------------------------------------------------
payment-service           payments        Handles payment processing
```

### Export resolved config

```bash
$ appreg export payment-service --env prod --format yaml
app: payment-service
config:
  db_host: prod-db.internal
  log_level: info
  replicas: 5
environment: prod
```

### Delete an application

```bash
$ appreg delete payment-service --yes
Deleted application 'payment-service'.
```

## Storage Format

Each application is stored as a YAML file in `./registry/<app-name>.yaml`:

```yaml
name: payment-service
team: payments
description: Handles payment processing
defaults:
  replicas: 2
  log_level: info
  db_host: localhost
environments:
  dev:
    log_level: debug
  prod:
    replicas: 5
    db_host: prod-db.internal
```

## Running Tests

```bash
cd part-3-python-cli
python -m pytest tests/ -v
```

## Assumptions and Tradeoffs

- **Flat config keys only** — no nested config. This keeps resolution logic simple and predictable. Deep merge introduces ambiguity (replace vs merge nested objects).
- **Three environments** — `dev`, `staging`, `prod` are hardcoded as valid environments. Adding more requires a code change. In production, this would be configurable.
- **Local YAML storage** — suitable for single-user/demo. In production, back this with a database or Git repository.
- **No authentication** — local CLI tool. A production version would integrate with RBAC.

## What I Would Do Next

- Add `bulk import` command to load apps from a multi-document YAML file
- Support nested/deep-merge configuration with explicit merge strategy
- Add `--dry-run` flag to preview changes without writing
- Add Kubernetes values.yaml rendering (`appreg render payment-service --env prod`)
- Configurable environment list via a global config file
- JSON Schema validation for config values
- Git-backed storage with change history
