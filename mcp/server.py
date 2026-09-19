"""MCP server exposing a small, scoped set of Azure operations tools.

Every tool is confined to one resource group. Reads are unrestricted within
it; the single write action (restarting a container app) is gated by the
agent's approval policy in Foundry and by a custom Azure role that grants
nothing else.

Azure is called over its REST APIs with the server's managed identity, so
there are no SDK version surprises and every request is visible in this file.
"""

import hmac
import os
import re
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta
from typing import Any

import httpx
from azure.identity import DefaultAzureCredential
from mcp.server import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

ARM = "https://management.azure.com"
ARM_SCOPE = "https://management.azure.com/.default"
LOGS = "https://api.loganalytics.io"
LOGS_SCOPE = "https://api.loganalytics.io/.default"

RESOURCES_API = "2021-04-01"
CONTAINER_APPS_API = "2026-01-01"

# Azure resource names: letters, digits, and hyphens.
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,62}$")

MAX_ROWS = 50
MAX_QUERY_CHARS = 2000

_credential = DefaultAzureCredential()
_tokens: dict[str, Any] = {}


def _config(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name} is not configured")
    return value


def _token(scope: str) -> str:
    """Cached bearer token; DefaultAzureCredential refreshes near expiry."""
    token = _tokens.get(scope)
    if token is None or token.expires_on - 300 < time.time():
        token = _credential.get_token(scope)
        _tokens[scope] = token
    return token.token


def _require_name(value: str) -> str:
    if not NAME.match(value):
        raise ValueError(f"{value!r} is not a valid Azure resource name")
    return value


async def _get(url: str, scope: str, **params: str) -> dict:
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.get(
            url, params=params, headers={"Authorization": f"Bearer {_token(scope)}"}
        )
    response.raise_for_status()
    return response.json()


mcp = MCPServer("azure-ops")


@mcp.tool()
async def list_resources() -> list[dict]:
    """List every Azure resource in the lab resource group.

    Returns each resource's name, type, and location. Use this first to find
    out what exists before asking about a specific resource.
    """
    rg = _config("LAB_RESOURCE_GROUP")
    body = await _get(
        f"{ARM}/subscriptions/{_config('AZURE_SUBSCRIPTION_ID')}/resourceGroups/{rg}/resources",
        ARM_SCOPE,
        **{"api-version": RESOURCES_API},
    )
    return [
        {"name": r["name"], "type": r["type"], "location": r.get("location", "")}
        for r in body.get("value", [])
    ]


@mcp.tool()
async def container_app_status(name: str) -> dict:
    """Report the health of one container app: provisioning state, running
    status, its active revision, and the URL it serves.

    Args:
        name: Container app name, as returned by list_resources.
    """
    rg = _config("LAB_RESOURCE_GROUP")
    body = await _get(
        f"{ARM}/subscriptions/{_config('AZURE_SUBSCRIPTION_ID')}/resourceGroups/{rg}"
        f"/providers/Microsoft.App/containerApps/{_require_name(name)}",
        ARM_SCOPE,
        **{"api-version": CONTAINER_APPS_API},
    )
    props = body.get("properties", {})
    return {
        "name": body.get("name"),
        "provisioning_state": props.get("provisioningState"),
        "running_status": props.get("runningStatus"),
        "latest_ready_revision": props.get("latestReadyRevisionName"),
        "url": (props.get("configuration", {}).get("ingress", {}) or {}).get("fqdn"),
    }


@mcp.tool()
async def query_logs(kusto: str, hours: int = 1) -> dict:
    """Run a read-only Kusto query against the lab's Log Analytics workspace.

    Useful tables: ContainerAppConsoleLogs_CL (application output),
    ContainerAppSystemLogs_CL (platform events), AppRequests and
    AppDependencies (Application Insights).

    Args:
        kusto: The Kusto query. Results are capped at 50 rows.
        hours: How far back to search, 1 to 24 hours.
    """
    if len(kusto) > MAX_QUERY_CHARS:
        raise ValueError("query is too long")
    if not 1 <= hours <= 24:
        raise ValueError("hours must be between 1 and 24")

    workspace = _config("LOG_ANALYTICS_WORKSPACE_ID")
    async with httpx.AsyncClient(timeout=60.0) as client:
        response = await client.post(
            f"{LOGS}/v1/workspaces/{workspace}/query",
            headers={"Authorization": f"Bearer {_token(LOGS_SCOPE)}"},
            json={
                "query": f"{kusto}\n| take {MAX_ROWS}",
                "timespan": f"PT{int(timedelta(hours=hours).total_seconds() // 3600)}H",
            },
        )
    if response.status_code >= 400:
        # Surface the query error to the agent so it can correct itself.
        return {"error": response.json().get("error", {}).get("message", "query failed")}

    tables = response.json().get("tables", [])
    if not tables:
        return {"columns": [], "rows": []}
    return {
        "columns": [c["name"] for c in tables[0]["columns"]],
        "rows": tables[0]["rows"][:MAX_ROWS],
    }


@mcp.tool()
async def restart_container_app(name: str) -> dict:
    """Restart a container app's active revision. This interrupts in-flight
    requests, so it requires human approval before it runs.

    Args:
        name: Container app name, as returned by list_resources.
    """
    rg = _config("LAB_RESOURCE_GROUP")
    base = (
        f"{ARM}/subscriptions/{_config('AZURE_SUBSCRIPTION_ID')}/resourceGroups/{rg}"
        f"/providers/Microsoft.App/containerApps/{_require_name(name)}"
    )
    current = await _get(base, ARM_SCOPE, **{"api-version": CONTAINER_APPS_API})
    revision = current.get("properties", {}).get("latestReadyRevisionName")
    if not revision:
        return {"restarted": False, "reason": "no ready revision to restart"}

    async with httpx.AsyncClient(timeout=60.0) as client:
        response = await client.post(
            f"{base}/revisions/{revision}/restart",
            params={"api-version": CONTAINER_APPS_API},
            headers={"Authorization": f"Bearer {_token(ARM_SCOPE)}"},
        )
    response.raise_for_status()
    return {"restarted": True, "app": name, "revision": revision}


async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


class RequireKey:
    """Shared-key check in front of the MCP endpoint.

    Foundry presents this key from a project connection, so the tool server
    is never anonymously callable. /healthz stays open for platform probes.
    """

    def __init__(self, app: Any, key: str) -> None:
        self.app = app
        self.key = key

    async def __call__(self, scope: dict, receive: Any, send: Any) -> None:
        if scope["type"] == "http" and not scope["path"].startswith("/healthz"):
            headers = dict(scope.get("headers") or [])
            presented = headers.get(b"x-lab-key", b"").decode()
            # Constant-time comparison; both values are short.
            if not hmac.compare_digest(presented, self.key):
                await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
                return
        await self.app(scope, receive, send)


@asynccontextmanager
async def lifespan(_: Starlette) -> AsyncIterator[None]:
    # A mounted app's own lifespan never runs, so the session manager has to
    # be started here or every MCP request fails.
    async with mcp.session_manager.run():
        yield


def build_app() -> Any:
    # Behind a real hostname the transport rejects every request with 421
    # until its Host allowlist names that hostname.
    hostname = os.environ.get("PUBLIC_HOSTNAME", "")
    allowed = [hostname, f"{hostname}:*"] if hostname else ["localhost", "localhost:*"]
    security = TransportSecuritySettings(allowed_hosts=allowed)

    routes = Starlette(
        routes=[
            Route("/healthz", healthz),
            Mount("/", app=mcp.streamable_http_app(transport_security=security)),
        ],
        lifespan=lifespan,
    )
    # Fail closed: an unauthenticated tool server would let anyone run these
    # actions against the subscription.
    return RequireKey(routes, _config("LAB_KEY"))


# Built by uvicorn at startup (see the Dockerfile's --factory flag) rather
# than at import, so tests can import this module without configuration.
