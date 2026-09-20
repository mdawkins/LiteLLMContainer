#!/usr/bin/env python3
"""Validate and reconcile deterministic LiteLLM broker routes.

The registry contains references to secrets, never secret values.  Mutating API
operations are dry-run unless --apply is supplied.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import secrets
import ssl
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
DEFAULT_REGISTRY = ROOT / "broker-registry.json"
DEFAULT_ENV = ROOT / ".env"
GENERATED = ROOT / ".generated"
SLUG = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
ENV_NAME = re.compile(r"^[A-Z_][A-Z0-9_]*$")
FORBIDDEN_KEYS = {"fallbacks", "default_fallbacks", "context_window_fallbacks"}
PASSTHROUGH_LIMITS = {
    "max_budget",
    "budget_duration",
    "tpm_limit",
    "rpm_limit",
    "max_parallel_requests",
    "model_tpm_limit",
    "model_rpm_limit",
    "model_max_budget",
    "blocked",
}


class RegistryError(ValueError):
    pass


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryError(f"cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise RegistryError(f"{path} must contain a JSON object")
    return value


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not ENV_NAME.fullmatch(key):
            raise RegistryError(f"{path}:{number}: invalid environment name {key!r}")
        values[key] = value.strip().strip("\"").strip("'")
    return values


def expand_env(value: str, env: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in env or not env[name]:
            raise RegistryError(f"environment variable {name} is required")
        return env[name]

    return re.sub(r"\$\{([A-Z_][A-Z0-9_]*)\}", replace, value)


def find_forbidden(value: Any, path: str = "registry") -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            if key in FORBIDDEN_KEYS:
                found.append(child_path)
            found.extend(find_forbidden(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(find_forbidden(child, f"{path}[{index}]"))
    return found


def enabled_accounts(registry: dict[str, Any], broker: str | None = None) -> list[dict[str, Any]]:
    return [
        account
        for account in registry.get("accounts", [])
        if account.get("enabled", False) and (broker is None or account.get("broker") == broker)
    ]


def route_name(account: dict[str, Any], model: dict[str, Any]) -> str:
    return f"{account['broker']}/{account['id']}/{model['route']}"


def route_names(registry: dict[str, Any]) -> list[str]:
    return [route_name(account, model) for account in enabled_accounts(registry) for model in account["models"]]


def resolve_grants(grants: list[str], routes: list[str]) -> list[str]:
    resolved: set[str] = set()
    for grant in grants:
        if grant == "*":
            resolved.update(routes)
        elif grant.endswith("/*"):
            prefix = grant[:-1]
            matches = [route for route in routes if route.startswith(prefix)]
            if not matches:
                raise RegistryError(f"grant {grant!r} matches no enabled routes")
            resolved.update(matches)
        elif grant in routes:
            resolved.add(grant)
        else:
            raise RegistryError(f"grant {grant!r} is not an enabled route")
    return sorted(resolved)


def validate(registry: dict[str, Any]) -> None:
    errors: list[str] = []
    if registry.get("version") != 1:
        errors.append("version must be 1")
    forbidden = find_forbidden(registry)
    if forbidden:
        errors.append("fallback configuration is forbidden: " + ", ".join(forbidden))

    accounts = registry.get("accounts")
    if not isinstance(accounts, list):
        errors.append("accounts must be a list")
        accounts = []

    account_keys: set[tuple[str, str]] = set()
    public_routes: set[str] = set()
    for index, account in enumerate(accounts):
        where = f"accounts[{index}]"
        if not isinstance(account, dict):
            errors.append(f"{where} must be an object")
            continue
        broker = account.get("broker")
        account_id = account.get("id")
        if not isinstance(account.get("enabled"), bool):
            errors.append(f"{where}.enabled must be true or false")
        if broker not in {"bedrock", "usai", "codex"}:
            errors.append(f"{where}.broker must be bedrock, usai, or codex")
        if not isinstance(account_id, str) or not SLUG.fullmatch(account_id):
            errors.append(f"{where}.id must be a lowercase route-safe slug")
        if isinstance(broker, str) and isinstance(account_id, str):
            key = (broker, account_id)
            if key in account_keys:
                errors.append(f"duplicate account {broker}/{account_id}")
            account_keys.add(key)
        models = account.get("models")
        if not isinstance(models, list) or not models:
            errors.append(f"{where}.models must be a non-empty list")
            continue
        if broker == "usai":
            if not account.get("api_base"):
                errors.append(f"{where}.api_base is required")
            if not ENV_NAME.fullmatch(str(account.get("api_key_env", ""))):
                errors.append(f"{where}.api_key_env must name an environment variable")
        if broker == "bedrock" and not ENV_NAME.fullmatch(str(account.get("region_env", ""))):
            errors.append(f"{where}.region_env must name an environment variable")
        if broker == "bedrock":
            access_env = account.get("aws_access_key_id_env")
            secret_env = account.get("aws_secret_access_key_env")
            if bool(access_env) != bool(secret_env):
                errors.append(
                    f"{where} must set both aws_access_key_id_env and aws_secret_access_key_env"
                )
            for key in ("aws_access_key_id_env", "aws_secret_access_key_env", "aws_session_token_env"):
                if account.get(key) and not ENV_NAME.fullmatch(str(account[key])):
                    errors.append(f"{where}.{key} must name an environment variable")
            if account.get("aws_role_name") and access_env:
                errors.append(f"{where} cannot combine aws_role_name with static credential references")
        if broker == "codex":
            if not account.get("auth_dir"):
                errors.append(f"{where}.auth_dir is required")
            if not ENV_NAME.fullmatch(str(account.get("worker_key_env", ""))):
                errors.append(f"{where}.worker_key_env must name an environment variable")
        local_routes: set[str] = set()
        for model_index, model in enumerate(models):
            model_where = f"{where}.models[{model_index}]"
            if not isinstance(model, dict):
                errors.append(f"{model_where} must be an object")
                continue
            short = model.get("route")
            if not isinstance(short, str) or not SLUG.fullmatch(short):
                errors.append(f"{model_where}.route must be a lowercase route-safe slug")
                continue
            if short in local_routes:
                errors.append(f"duplicate route {broker}/{account_id}/{short}")
            local_routes.add(short)
            if not isinstance(model.get("upstream"), str) or not model["upstream"]:
                errors.append(f"{model_where}.upstream is required")
            pricing = model.get("pricing", {})
            if not isinstance(pricing, dict):
                errors.append(f"{model_where}.pricing must be an object")
            else:
                for price_name, price in pricing.items():
                    if not isinstance(price, (int, float)) or isinstance(price, bool) or not math.isfinite(price) or price < 0:
                        errors.append(f"{model_where}.pricing.{price_name} must be a non-negative finite number")
            if isinstance(broker, str) and isinstance(account_id, str):
                public = f"{broker}/{account_id}/{short}"
                if public in public_routes:
                    errors.append(f"duplicate public route {public}")
                public_routes.add(public)

    routes = route_names(registry) if not errors else []
    organizations = registry.get("organizations", [])
    teams = registry.get("teams", [])
    if not isinstance(organizations, list):
        errors.append("organizations must be a list")
        organizations = []
    if not isinstance(teams, list):
        errors.append("teams must be a list")
        teams = []

    org_routes: dict[str, set[str]] = {}
    org_ids: set[str] = set()
    for index, org in enumerate(organizations):
        where = f"organizations[{index}]"
        if not isinstance(org, dict) or not org.get("id") or not org.get("alias"):
            errors.append(f"{where} requires id and alias")
            continue
        if org["id"] in org_ids:
            errors.append(f"duplicate organization id {org['id']}")
        org_ids.add(org["id"])
        try:
            models = resolve_grants(org.get("models", []), routes)
            if not models:
                errors.append(f"{where}.models must grant at least one route")
            org_routes[org["id"]] = set(models)
        except RegistryError as exc:
            errors.append(f"{where}: {exc}")

    team_ids: set[str] = set()
    for index, team in enumerate(teams):
        where = f"teams[{index}]"
        if not isinstance(team, dict) or not team.get("id") or not team.get("alias"):
            errors.append(f"{where} requires id and alias")
            continue
        if team["id"] in team_ids:
            errors.append(f"duplicate team id {team['id']}")
        team_ids.add(team["id"])
        org_id = team.get("organization_id")
        if org_id and org_id not in org_routes:
            errors.append(f"{where}.organization_id references an unknown organization")
        try:
            models = set(resolve_grants(team.get("models", []), routes))
            if not models:
                errors.append(f"{where}.models must grant at least one route")
            if org_id and not models.issubset(org_routes.get(org_id, set())):
                errors.append(f"{where} grants routes outside organization {org_id}")
        except RegistryError as exc:
            errors.append(f"{where}: {exc}")

    if errors:
        raise RegistryError("\n- ".join(["registry validation failed:"] + errors))


def load_registry(path: Path) -> dict[str, Any]:
    registry = read_json(path)
    validate(registry)
    return registry


def canonical_hash(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


class HtmlTableParser(HTMLParser):
    """Extract simple HTML tables without executing page JavaScript."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.tables: list[list[list[str]]] = []
        self._table: list[list[str]] | None = None
        self._row: list[str] | None = None
        self._cell: list[str] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag == "table" and self._table is None:
            self._table = []
        elif tag == "tr" and self._table is not None:
            self._row = []
        elif tag in {"th", "td"} and self._row is not None:
            self._cell = []

    def handle_data(self, data: str) -> None:
        if self._cell is not None:
            self._cell.append(data)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in {"th", "td"} and self._cell is not None and self._row is not None:
            value = re.sub(r"\\s+", " ", "".join(self._cell)).strip()
            self._row.append(value)
            self._cell = None
        elif tag == "tr" and self._row is not None and self._table is not None:
            if any(self._row):
                self._table.append(self._row)
            self._row = None
        elif tag == "table" and self._table is not None:
            if self._table:
                self.tables.append(self._table)
            self._table = None


def parse_html_tables(content: str) -> list[dict[str, Any]]:
    parser = HtmlTableParser()
    parser.feed(content)
    result: list[dict[str, Any]] = []
    for table_number, rows in enumerate(parser.tables, 1):
        headers = rows[0]
        result.append(
            {
                "table": table_number,
                "headers": headers,
                "rows": rows[1:],
            }
        )
    return result


def write_private_json(path: Path, value: Any) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def sync_usai(
    registry: dict[str, Any],
    env: dict[str, str],
    account_id: str,
    insecure: bool,
    pricing_html: Path | None,
    output: Path | None,
) -> None:
    matches = [a for a in registry.get("accounts", []) if a.get("broker") == "usai" and a.get("id") == account_id]
    if not matches:
        raise RegistryError(f"unknown USAI account {account_id!r}")
    account = matches[0]
    key_name = account["api_key_env"]
    token = os.environ.get(key_name) or env.get(key_name)
    if not token:
        raise RegistryError(f"{key_name} is not set")

    api = Api(account["api_base"], token, insecure=insecure)
    response = api.request("GET", "/models")
    rows = extract_list(response, "models")
    configured = {model["upstream"] for model in account["models"]}
    discovered = [str(row.get("id")) for row in rows if row.get("id")]
    destination = output or (GENERATED / "usai" / account_id / "models.json")
    write_private_json(
        destination,
        {
            "retrieved_at": datetime.now(timezone.utc).isoformat(),
            "broker": "usai",
            "account": account_id,
            "api_base": account["api_base"],
            "models": response,
        },
    )
    print(f"[brokerctl] saved USAI catalog ({len(discovered)} model(s)) to {destination}")
    print(f"[brokerctl] known={sum(model_id in configured for model_id in discovered)} new={sum(model_id not in configured for model_id in discovered)}")

    if pricing_html:
        try:
            html_content = pricing_html.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            raise RegistryError(f"cannot read pricing HTML {pricing_html}: {exc}") from exc
        pricing_destination = destination.parent / "pricing.html"
        pricing_destination.write_text(html_content, encoding="utf-8")
        os.chmod(pricing_destination, 0o600)
        candidates = destination.parent / "pricing-candidates.json"
        write_private_json(
            candidates,
            {
                "source": str(pricing_html),
                "saved_at": datetime.now(timezone.utc).isoformat(),
                "tables": parse_html_tables(html_content),
            },
        )
        print(f"[brokerctl] saved pricing HTML to {pricing_destination}")
        print(f"[brokerctl] extracted pricing table candidates to {candidates}; review before applying")


def desired_model(account: dict[str, Any], model: dict[str, Any]) -> dict[str, Any]:
    broker = account["broker"]
    upstream = model["upstream"]
    params: dict[str, Any] = dict(model.get("params", {}))
    if broker == "usai":
        params.update(
            {
                "model": upstream if "/" in upstream else f"openai/{upstream}",
                "api_base": account["api_base"],
                "api_key": f"os.environ/{account['api_key_env']}",
            }
        )
    elif broker == "bedrock":
        params.update(
            {
                "model": upstream if upstream.startswith("bedrock/") else f"bedrock/{upstream}",
                "aws_region_name": f"os.environ/{account['region_env']}",
            }
        )
        if account.get("aws_role_name"):
            params["aws_role_name"] = account["aws_role_name"]
        if account.get("aws_access_key_id_env"):
            params["aws_access_key_id"] = f"os.environ/{account['aws_access_key_id_env']}"
            params["aws_secret_access_key"] = f"os.environ/{account['aws_secret_access_key_env']}"
        if account.get("aws_session_token_env"):
            params["aws_session_token"] = f"os.environ/{account['aws_session_token_env']}"
    else:
        params.update(
            {
                "model": upstream if upstream.startswith("openai/") else f"openai/{upstream}",
                "api_base": f"http://litellm-codex-{account['id']}:4000/v1",
                "api_key": f"os.environ/{account['worker_key_env']}",
            }
        )

    info: dict[str, Any] = {
        "managed_by": "brokerctl",
        "registry_route": route_name(account, model),
        "broker": broker,
        "broker_account": account["id"],
        "mode": model.get("mode", "chat"),
    }
    info.update(model.get("capabilities", {}))
    info.update(model.get("pricing", {}))
    if broker == "codex" and "pricing" not in model:
        info["cost_accounting"] = "subscription-cost-not-reported"

    payload = {"model_name": route_name(account, model), "litellm_params": params, "model_info": info}
    info["registry_hash"] = canonical_hash(payload)
    return payload


def desired_models(registry: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        desired_model(account, model)
        for account in enabled_accounts(registry)
        for model in account["models"]
    ]


def worker_service_name(account_id: str) -> str:
    return f"litellm-codex-{account_id}"


def check_runtime(registry: dict[str, Any], env: dict[str, str]) -> None:
    for account in enabled_accounts(registry):
        if account["broker"] == "usai" and not env.get(account["api_key_env"]):
            raise RegistryError(
                f"enabled USAI account {account['id']} requires {account['api_key_env']}"
            )
        if account["broker"] == "codex":
            if not env.get(account["worker_key_env"]):
                raise RegistryError(
                    f"enabled Codex account {account['id']} requires {account['worker_key_env']}; run ensure-env"
                )
            auth_file = Path(expand_env(account["auth_dir"], env)).expanduser() / "auth.json"
            if not auth_file.is_file():
                raise RegistryError(
                    f"enabled Codex account {account['id']} has no {auth_file}; run import-codex-auth first"
                )
        if account["broker"] == "bedrock":
            for key in ("aws_access_key_id_env", "aws_secret_access_key_env", "aws_session_token_env"):
                env_name = account.get(key)
                if env_name and not env.get(env_name):
                    raise RegistryError(
                        f"enabled Bedrock account {account['id']} requires {env_name}"
                    )


def render(registry: dict[str, Any]) -> None:
    GENERATED.mkdir(mode=0o700, parents=True, exist_ok=True)
    central_env: dict[str, str] = {}
    services: dict[str, Any] = {"litellm-proxy": {"environment": central_env}}
    worker_configs: dict[str, dict[str, Any]] = {}

    for account in enabled_accounts(registry):
        if account["broker"] == "usai":
            name = account["api_key_env"]
            central_env[name] = f"${{{name}}}"
        elif account["broker"] == "bedrock":
            region_name = account["region_env"]
            central_env[region_name] = (
                "${AWS_REGION:-us-east-1}" if region_name == "AWS_REGION" else f"${{{region_name}}}"
            )
            for key in ("aws_access_key_id_env", "aws_secret_access_key_env", "aws_session_token_env"):
                name = account.get(key)
                if name:
                    central_env[name] = f"${{{name}}}"
        elif account["broker"] == "codex":
            name = account["worker_key_env"]
            central_env[name] = f"${{{name}}}"
            account_id = account["id"]
            worker_dir = GENERATED / "codex" / account_id
            worker_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            worker_models = []
            for model in account["models"]:
                upstream = model["upstream"]
                worker_models.append(
                    {
                        "model_name": upstream,
                        "litellm_params": {
                            "model": upstream if upstream.startswith("chatgpt/") else f"chatgpt/{upstream}"
                        },
                    }
                )
            worker_config = {
                "model_list": worker_models,
                "litellm_settings": {"drop_params": True, "modify_params": True},
                "general_settings": {"set_verbose": False},
            }
            worker_configs[account_id] = worker_config
            (worker_dir / "config.json").write_text(
                json.dumps(worker_config, indent=2) + "\n", encoding="utf-8"
            )
            service = worker_service_name(account_id)
            services[service] = {
                "container_name": service,
                "image": "localhost/litellm-proxy:local",
                "restart": "unless-stopped",
                "volumes": [
                    f"./.generated/codex/{account_id}/config.json:/app/config.yaml:ro",
                    f"{account['auth_dir']}:/app/.codex",
                ],
                "environment": {
                    "LITELLM_MASTER_KEY": f"${{{name}}}",
                    "CHATGPT_TOKEN_DIR": "/app/.codex",
                },
                "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"],
                "networks": ["internal_net"],
            }

    compose = {"services": services}
    (GENERATED / "compose-brokers.yaml").write_text(json.dumps(compose, indent=2) + "\n", encoding="utf-8")
    fingerprint = canonical_hash({"compose": compose, "worker_configs": worker_configs})
    (GENERATED / "runtime-fingerprint").write_text(fingerprint + "\n", encoding="utf-8")
    print(f"[brokerctl] rendered {GENERATED / 'compose-brokers.yaml'}")


def ensure_env(registry: dict[str, Any], env_path: Path) -> None:
    env_path.touch(mode=0o600, exist_ok=True)
    current = read_env(env_path)
    additions: list[str] = []
    for account in enabled_accounts(registry, "codex"):
        name = account["worker_key_env"]
        if not current.get(name):
            additions.append(f"{name}=sk-{secrets.token_urlsafe(32)}")
    if additions:
        with env_path.open("a", encoding="utf-8") as handle:
            if env_path.stat().st_size and not env_path.read_bytes().endswith(b"\n"):
                handle.write("\n")
            handle.write("\n".join(additions) + "\n")
        print("[brokerctl] generated missing Codex worker key(s): " + ", ".join(x.split("=", 1)[0] for x in additions))
    os.chmod(env_path, 0o600)


class Api:
    def __init__(self, base_url: str, token: str, insecure: bool = False):
        if not base_url.startswith(("http://", "https://")):
            base_url = "https://" + base_url
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.context = ssl._create_unverified_context() if insecure else ssl.create_default_context()

    def request(self, method: str, path: str, data: dict[str, Any] | None = None) -> Any:
        body = json.dumps(data).encode() if data is not None else None
        request = urllib.request.Request(
            self.base_url + path,
            data=body,
            method=method,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            raise RuntimeError(f"{method} {path} failed: HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"{method} {path} failed: {exc.reason}") from exc


def extract_list(value: Any, *keys: str) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict):
        for key in keys + ("data",):
            child = value.get(key)
            if isinstance(child, list):
                return [item for item in child if isinstance(item, dict)]
    return []


def model_info(row: dict[str, Any]) -> dict[str, Any]:
    info = row.get("model_info", {})
    if isinstance(info, str):
        try:
            info = json.loads(info)
        except json.JSONDecodeError:
            return {}
    return info if isinstance(info, dict) else {}


def apply_models(api: Api, registry: dict[str, Any], apply: bool, prune: bool) -> None:
    desired = desired_models(registry)
    current = extract_list(api.request("GET", "/model/info"), "models")
    managed: dict[str, dict[str, Any]] = {}
    for row in current:
        info = model_info(row)
        if info.get("managed_by") == "brokerctl" and info.get("registry_route"):
            managed[info["registry_route"]] = row

    desired_names: set[str] = set()
    changes = 0
    for payload in desired:
        name = payload["model_name"]
        desired_names.add(name)
        existing = managed.get(name)
        if existing is None:
            action = "CREATE"
            method, path = "POST", "/model/new"
        elif model_info(existing).get("registry_hash") != payload["model_info"]["registry_hash"]:
            model_id = model_info(existing).get("id") or existing.get("model_id") or existing.get("id")
            if not model_id:
                raise RuntimeError(f"cannot update {name}: /model/info returned no deployment id")
            action = "UPDATE"
            method, path = "PATCH", f"/model/{urllib.parse.quote(str(model_id), safe='')}/update"
        else:
            print(f"UNCHANGED {name}")
            continue
        changes += 1
        print(f"{action} {name}")
        if apply:
            api.request(method, path, payload)

    stale = sorted(set(managed) - desired_names)
    for name in stale:
        row = managed[name]
        model_id = model_info(row).get("id") or row.get("model_id") or row.get("id")
        if prune:
            changes += 1
            print(f"DELETE {name}")
            if apply:
                if not model_id:
                    raise RuntimeError(f"cannot delete {name}: /model/info returned no deployment id")
                api.request("POST", "/model/delete", {"id": model_id})
        else:
            print(f"STALE {name} (use --prune to remove)")
    print(f"[brokerctl] {'applied' if apply else 'planned'} {changes} model change(s)")


def entity_payload(entity: dict[str, Any], routes: list[str], kind: str) -> dict[str, Any]:
    payload: dict[str, Any] = {
        f"{kind}_id": entity["id"],
        f"{kind}_alias": entity["alias"],
        "models": resolve_grants(entity["models"], routes),
    }
    if kind == "team" and entity.get("organization_id"):
        payload["organization_id"] = entity["organization_id"]
    for key in PASSTHROUGH_LIMITS:
        if key in entity:
            payload[key] = entity[key]
    return payload


def apply_access(api: Api, registry: dict[str, Any], apply: bool) -> None:
    routes = route_names(registry)
    if not registry.get("organizations") and not registry.get("teams"):
        print("[brokerctl] no registry-managed organizations or teams")
        return
    model_rows = extract_list(api.request("GET", "/model/info"), "models")
    available = {row.get("model_name") for row in model_rows}
    missing_routes = sorted(set(routes) - available)
    if missing_routes:
        raise RuntimeError(
            "cannot apply access before models are reconciled; missing routes: "
            + ", ".join(missing_routes)
        )
    org_rows = extract_list(api.request("GET", "/organization/list"), "organizations")
    team_rows = extract_list(api.request("GET", "/team/list"), "teams")
    org_ids = {row.get("organization_id") for row in org_rows}
    team_ids = {row.get("team_id") for row in team_rows}
    changes = 0
    for org in registry.get("organizations", []):
        payload = entity_payload(org, routes, "organization")
        exists = org["id"] in org_ids
        print(f"{'UPDATE' if exists else 'CREATE'} organization {org['id']} ({len(payload['models'])} routes)")
        changes += 1
        if apply:
            api.request("PATCH" if exists else "POST", "/organization/update" if exists else "/organization/new", payload)
    for team in registry.get("teams", []):
        payload = entity_payload(team, routes, "team")
        exists = team["id"] in team_ids
        print(f"{'UPDATE' if exists else 'CREATE'} team {team['id']} ({len(payload['models'])} routes)")
        changes += 1
        if apply:
            api.request("POST", "/team/update" if exists else "/team/new", payload)
    print(f"[brokerctl] {'applied' if apply else 'planned'} {changes} access change(s)")


def import_codex_auth(registry: dict[str, Any], env: dict[str, str], account_id: str, source: Path) -> None:
    matches = [a for a in registry.get("accounts", []) if a.get("broker") == "codex" and a.get("id") == account_id]
    if not matches:
        raise RegistryError(f"unknown Codex account {account_id!r}")
    account = matches[0]
    source_data = read_json(source.expanduser())
    tokens = source_data.get("tokens", source_data)
    if not isinstance(tokens, dict):
        raise RegistryError(f"{source} has no token object")
    flattened = {
        key: tokens[key]
        for key in ("access_token", "refresh_token", "id_token", "account_id")
        if isinstance(tokens.get(key), str) and tokens[key]
    }
    if "last_refresh" in source_data:
        flattened["last_refresh"] = source_data["last_refresh"]
    missing = {"access_token", "refresh_token", "account_id"} - flattened.keys()
    if missing:
        raise RegistryError(f"{source} is missing required Codex fields: {', '.join(sorted(missing))}")
    destination_dir = Path(expand_env(account["auth_dir"], env)).expanduser()
    destination_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(destination_dir, 0o700)
    destination = destination_dir / "auth.json"
    descriptor, temporary = tempfile.mkstemp(prefix=".auth.", dir=destination_dir)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(flattened, handle, separators=(",", ":"))
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"[brokerctl] imported Codex auth for {account_id} to {destination} (mode 0600)")


def discover_usai(registry: dict[str, Any], env: dict[str, str], account_id: str, insecure: bool) -> None:
    matches = [a for a in registry.get("accounts", []) if a.get("broker") == "usai" and a.get("id") == account_id]
    if not matches:
        raise RegistryError(f"unknown USAI account {account_id!r}")
    account = matches[0]
    key_name = account["api_key_env"]
    token = os.environ.get(key_name) or env.get(key_name)
    if not token:
        raise RegistryError(f"{key_name} is not set")
    api = Api(account["api_base"], token, insecure=insecure)
    rows = extract_list(api.request("GET", "/models"), "models")
    discovered = sorted({str(row.get("id")) for row in rows if row.get("id")})
    configured = {model["upstream"] for model in account["models"]}
    for model_id in discovered:
        print(f"{'KNOWN' if model_id in configured else 'NEW'} {model_id}")
    print(f"[brokerctl] discovered {len(discovered)} USAI model(s); registry was not changed")


def make_api(args: argparse.Namespace, env: dict[str, str]) -> Api:
    base_url = args.base_url or env.get("LITELLM_BASE_URL") or "https://localhost"
    token = args.master_key or env.get("LITELLM_MASTER_KEY")
    if not token:
        raise RegistryError("LITELLM_MASTER_KEY is not set")
    return Api(base_url, token, insecure=args.insecure)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    result.add_argument("--env-file", type=Path, default=DEFAULT_ENV)
    sub = result.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    sub.add_parser("preflight")
    sub.add_parser("render")
    sub.add_parser("ensure-env")
    sub.add_parser("routes")
    sub.add_parser("worker-services")
    for name in ("apply-models", "apply-access"):
        command = sub.add_parser(name)
        command.add_argument("--base-url")
        command.add_argument("--master-key")
        command.add_argument("--insecure", action="store_true")
        command.add_argument("--apply", action="store_true", help="perform writes; otherwise show a dry-run")
        if name == "apply-models":
            command.add_argument("--prune", action="store_true", help="delete stale brokerctl-managed routes")
    auth = sub.add_parser("import-codex-auth")
    auth.add_argument("account")
    auth.add_argument("--source", type=Path, default=Path("~/.codex/auth.json"))
    discover = sub.add_parser("discover-usai")
    discover.add_argument("account")
    discover.add_argument("--insecure", action="store_true")
    sync = sub.add_parser("sync-usai")
    sync.add_argument("account")
    sync.add_argument("--insecure", action="store_true")
    sync.add_argument(
        "--pricing-html",
        type=Path,
        help="HTML saved from the USAI console pricing page (SSO/PIV is performed interactively)",
    )
    sync.add_argument(
        "--output",
        type=Path,
        help="catalog JSON destination (default: .generated/usai/<account>/models.json)",
    )
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        registry = load_registry(args.registry)
        env = {**read_env(args.env_file), **os.environ}
        if args.command == "validate":
            print(f"[brokerctl] valid: {len(route_names(registry))} enabled route(s)")
        elif args.command == "preflight":
            check_runtime(registry, env)
            print("[brokerctl] runtime credentials and auth files are present")
        elif args.command == "render":
            render(registry)
        elif args.command == "ensure-env":
            ensure_env(registry, args.env_file)
        elif args.command == "routes":
            print("\n".join(route_names(registry)))
        elif args.command == "worker-services":
            print(" ".join(worker_service_name(a["id"]) for a in enabled_accounts(registry, "codex")))
        elif args.command == "apply-models":
            apply_models(make_api(args, env), registry, args.apply, args.prune)
        elif args.command == "apply-access":
            apply_access(make_api(args, env), registry, args.apply)
        elif args.command == "import-codex-auth":
            import_codex_auth(registry, env, args.account, args.source)
        elif args.command == "discover-usai":
            discover_usai(registry, env, args.account, args.insecure)
        elif args.command == "sync-usai":
            sync_usai(registry, env, args.account, args.insecure, args.pricing_html, args.output)
        return 0
    except (RegistryError, RuntimeError) as exc:
        print(f"brokerctl: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
