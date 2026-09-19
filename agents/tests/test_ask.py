"""The approval gate is the security boundary of this lab, so it is tested
against a fake Foundry client: reads run, writes need a human, and nothing
the model returns can change that.
"""

import types

import pytest

import ask
from ops_agent import READ_ONLY_TOOLS


def approval(tool: str, request_id: str = "req-1", arguments: str = "{}"):
    return types.SimpleNamespace(
        type="mcp_approval_request",
        id=request_id,
        name=tool,
        arguments=arguments,
        server_label="azure-ops",
    )


def message(text: str):
    return types.SimpleNamespace(type="message", id="msg-1")


class FakeResponses:
    """Returns each queued response in turn and records what was sent."""

    def __init__(self, queue):
        self.queue = list(queue)
        self.sent = []

    def create(self, **kwargs):
        self.sent.append(kwargs)
        output, text = self.queue.pop(0) if self.queue else ([], "done")
        return types.SimpleNamespace(id=f"resp-{len(self.sent)}", output=output, output_text=text)


@pytest.fixture
def fake_project(monkeypatch):
    def install(queue):
        responses = FakeResponses(queue)
        openai = types.SimpleNamespace(responses=responses)
        client = types.SimpleNamespace(get_openai_client=lambda: openai)
        monkeypatch.setattr(ask, "AIProjectClient", lambda **_: client)
        monkeypatch.setattr(ask, "DefaultAzureCredential", lambda: object())
        monkeypatch.setenv("PROJECT_ENDPOINT", "https://x.services.ai.azure.com/api/projects/p")
        return responses

    return install


def decisions_from(responses, call_index=1):
    return responses.sent[call_index]["input"]


@pytest.mark.parametrize("tool", READ_ONLY_TOOLS)
def test_read_only_tools_are_approved_automatically(fake_project, tool):
    responses = fake_project([([approval(tool)], ""), ([], "All healthy.")])

    outcome = ask.ask("how are things?")

    assert outcome.approved == [tool]
    assert outcome.refused == []
    assert decisions_from(responses)[0]["approve"] is True
    assert outcome.answer == "All healthy."


def test_write_tool_is_refused_without_explicit_permission(fake_project):
    responses = fake_project(
        [([approval("restart_container_app")], ""), ([], "I did not restart it.")]
    )

    outcome = ask.ask("restart the tool server")

    assert outcome.refused == ["restart_container_app"]
    assert outcome.approved == []
    assert decisions_from(responses)[0]["approve"] is False


def test_write_tool_runs_only_when_a_human_allows_it(fake_project):
    responses = fake_project([([approval("restart_container_app")], ""), ([], "Restarted.")])

    outcome = ask.ask("restart the tool server", allow_writes=True)

    assert outcome.approved == ["restart_container_app"]
    assert decisions_from(responses)[0]["approve"] is True


def test_unknown_tools_are_treated_as_writes(fake_project):
    """A tool added to the server but not to the read-only list must not be
    approved automatically."""
    responses = fake_project([([approval("delete_everything")], ""), ([], "Refused.")])

    outcome = ask.ask("clean up")

    assert outcome.refused == ["delete_everything"]
    assert decisions_from(responses)[0]["approve"] is False


def test_each_approval_is_answered_by_request_id(fake_project):
    responses = fake_project(
        [
            (
                [
                    approval("list_resources", "req-a"),
                    approval("restart_container_app", "req-b"),
                ],
                "",
            ),
            ([], "Listed, but did not restart."),
        ]
    )

    ask.ask("look around and restart anything unhealthy")

    sent = decisions_from(responses)
    assert [(d["approval_request_id"], d["approve"]) for d in sent] == [
        ("req-a", True),
        ("req-b", False),
    ]


def test_conversation_continues_from_the_previous_response(fake_project):
    responses = fake_project([([approval("list_resources")], ""), ([], "Done.")])

    ask.ask("what is running?")

    assert responses.sent[1]["previous_response_id"] == "resp-1"


def test_repeated_approval_rounds_terminate(fake_project):
    # A server that asks forever must not loop forever.
    responses = fake_project([([approval("list_resources", f"req-{i}")], "") for i in range(20)])

    ask.ask("keep going")

    assert len(responses.sent) <= ask.MAX_ROUNDS + 1


def test_no_tool_calls_returns_the_answer_directly(fake_project):
    responses = fake_project([([message("hi")], "Nothing to do.")])

    outcome = ask.ask("hello")

    assert outcome.answer == "Nothing to do."
    assert outcome.approved == [] and outcome.refused == []
    assert len(responses.sent) == 1
