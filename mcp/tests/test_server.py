import json

import httpx
import pytest
from starlette.testclient import TestClient

import server


@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("AZURE_SUBSCRIPTION_ID", "sub-1234")
    monkeypatch.setenv("LAB_RESOURCE_GROUP", "rg-agentops-lab")
    monkeypatch.setenv("LOG_ANALYTICS_WORKSPACE_ID", "ws-1234")
    monkeypatch.setenv("LAB_KEY", "correct-key")
    monkeypatch.setattr(server, "_token", lambda scope: "fake-token")


def fake_http(monkeypatch, handler):
    """Route every httpx request in the server through `handler`."""

    class FakeClient:
        def __init__(self, **_):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_):
            return False

        async def get(self, url, params=None, headers=None):
            return handler("GET", url, params, headers, None)

        async def post(self, url, params=None, headers=None, json=None):
            return handler("POST", url, params, headers, json)

    monkeypatch.setattr(server.httpx, "AsyncClient", FakeClient)


def response(payload, status=200, url="https://management.azure.com/x"):
    return httpx.Response(status, json=payload, request=httpx.Request("GET", url))


# --------------------------------------------------------------------------
# Scope and input guards
# --------------------------------------------------------------------------


@pytest.mark.parametrize("name", ["../secrets", "app name", "app/../../other", "-bad", "", "a" * 64])
def test_invalid_resource_names_are_rejected(name):
    with pytest.raises(ValueError):
        server._require_name(name)


@pytest.mark.anyio
async def test_query_rejects_oversized_input():
    with pytest.raises(ValueError):
        await server.query_logs("x" * (server.MAX_QUERY_CHARS + 1))


@pytest.mark.anyio
@pytest.mark.parametrize("hours", [0, 25, -1])
async def test_query_rejects_out_of_range_window(hours):
    with pytest.raises(ValueError):
        await server.query_logs("AppRequests", hours=hours)


# --------------------------------------------------------------------------
# Tools
# --------------------------------------------------------------------------


@pytest.mark.anyio
async def test_list_resources_is_scoped_to_the_lab_group(monkeypatch):
    seen = {}

    def handler(method, url, params, headers, body):
        seen["url"] = url
        return response({"value": [{"name": "ca-x", "type": "Microsoft.App/containerApps", "location": "eastus2"}]})

    fake_http(monkeypatch, handler)
    result = await server.list_resources()

    assert "/resourceGroups/rg-agentops-lab/resources" in seen["url"]
    assert result == [{"name": "ca-x", "type": "Microsoft.App/containerApps", "location": "eastus2"}]


@pytest.mark.anyio
async def test_container_app_status_summarizes_health(monkeypatch):
    payload = {
        "name": "ca-x",
        "properties": {
            "provisioningState": "Succeeded",
            "runningStatus": "Running",
            "latestReadyRevisionName": "ca-x--abc123",
            "configuration": {"ingress": {"fqdn": "ca-x.eastus2.azurecontainerapps.io"}},
        },
    }
    fake_http(monkeypatch, lambda *a: response(payload))

    assert await server.container_app_status("ca-x") == {
        "name": "ca-x",
        "provisioning_state": "Succeeded",
        "running_status": "Running",
        "latest_ready_revision": "ca-x--abc123",
        "url": "ca-x.eastus2.azurecontainerapps.io",
    }


@pytest.mark.anyio
async def test_query_logs_caps_rows_and_sends_timespan(monkeypatch):
    sent = {}

    def handler(method, url, params, headers, body):
        sent.update(body=body, url=url)
        return response({"tables": [{"columns": [{"name": "Count"}], "rows": [[1], [2]]}]})

    fake_http(monkeypatch, handler)
    result = await server.query_logs("AppRequests | count", hours=6)

    assert f"take {server.MAX_ROWS}" in sent["body"]["query"]
    assert sent["body"]["timespan"] == "PT6H"
    assert result == {"columns": ["Count"], "rows": [[1], [2]]}


@pytest.mark.anyio
async def test_query_error_is_returned_not_raised(monkeypatch):
    fake_http(
        monkeypatch,
        lambda *a: response({"error": {"message": "syntax error"}}, status=400),
    )

    assert await server.query_logs("not kusto") == {"error": "syntax error"}


@pytest.mark.anyio
async def test_restart_targets_the_active_revision(monkeypatch):
    calls = []

    def handler(method, url, params, headers, body):
        calls.append((method, url))
        if method == "GET":
            return response({"properties": {"latestReadyRevisionName": "ca-x--abc123"}})
        return response({}, status=200)

    fake_http(monkeypatch, handler)
    result = await server.restart_container_app("ca-x")

    assert result == {"restarted": True, "app": "ca-x", "revision": "ca-x--abc123"}
    assert calls[-1][0] == "POST"
    assert calls[-1][1].endswith("/revisions/ca-x--abc123/restart")


@pytest.mark.anyio
async def test_restart_is_a_no_op_without_a_ready_revision(monkeypatch):
    fake_http(monkeypatch, lambda *a: response({"properties": {}}))

    result = await server.restart_container_app("ca-x")

    assert result["restarted"] is False


@pytest.mark.anyio
async def test_restart_rejects_a_name_outside_the_lab(monkeypatch):
    called = []
    fake_http(monkeypatch, lambda *a: called.append(a) or response({}))

    with pytest.raises(ValueError):
        await server.restart_container_app("../../other-rg/apps/prod")

    assert called == [], "a malformed name must never reach Azure"


# --------------------------------------------------------------------------
# Transport: authentication and health
# --------------------------------------------------------------------------


@pytest.fixture
def client():
    return TestClient(server.build_app())


def test_healthz_needs_no_key(client):
    assert client.get("/healthz").json() == {"status": "ok"}


@pytest.mark.parametrize("headers", [{}, {"x-lab-key": "wrong"}, {"x-lab-key": ""}])
def test_mcp_endpoint_requires_the_key(client, headers):
    assert client.post("/mcp", headers=headers, content="{}").status_code == 401


def test_correct_key_reaches_the_mcp_transport():
    # As a context manager so the app's lifespan runs and the MCP session
    # manager starts. Past the key check the transport itself answers, so a
    # 401 here would mean a valid key was rejected.
    with TestClient(server.build_app()) as running:
        response = running.post(
            "/mcp",
            headers={"x-lab-key": "correct-key", "content-type": "application/json"},
            content=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}),
        )
    assert response.status_code != 401


def test_server_refuses_to_start_without_a_key(monkeypatch):
    monkeypatch.delenv("LAB_KEY")
    with pytest.raises(RuntimeError):
        server.build_app()


@pytest.fixture
def anyio_backend():
    return "asyncio"
