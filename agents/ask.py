"""Ask the ops agent a question, enforcing the approval policy.

Foundry returns an approval request for every tool call the agent wants to
make. This client decides: read-only tools are approved automatically, and
anything that changes infrastructure is refused unless the caller passed
--allow-writes, which stands in for a human pressing approve.

The model never approves its own tool calls.
"""

import argparse
import json
import os
import sys
from dataclasses import dataclass, field

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

from ops_agent import AGENT_NAME, READ_ONLY_TOOLS

MAX_ROUNDS = 6


@dataclass
class Outcome:
    answer: str = ""
    approved: list[str] = field(default_factory=list)
    refused: list[str] = field(default_factory=list)

    def as_json(self) -> str:
        return json.dumps(
            {"answer": self.answer, "approved": self.approved, "refused": self.refused},
            indent=2,
        )


def ask(question: str, allow_writes: bool = False) -> Outcome:
    project = AIProjectClient(
        endpoint=os.environ["PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )
    openai = project.get_openai_client()
    agent_reference = {"agent_reference": {"name": AGENT_NAME, "type": "agent_reference"}}

    outcome = Outcome()
    response = openai.responses.create(input=question, extra_body=agent_reference)

    for _ in range(MAX_ROUNDS):
        decisions = []

        for item in response.output:
            if item.type != "mcp_approval_request" or not item.id:
                continue

            tool = getattr(item, "name", "<unknown>")
            arguments = getattr(item, "arguments", None)
            read_only = tool in READ_ONLY_TOOLS
            approve = read_only or allow_writes

            print(
                f"[approval] tool={tool} read_only={read_only} "
                f"decision={'approve' if approve else 'refuse'} args={arguments}",
                file=sys.stderr,
            )
            (outcome.approved if approve else outcome.refused).append(tool)
            decisions.append(
                {
                    "type": "mcp_approval_response",
                    "approve": approve,
                    "approval_request_id": item.id,
                }
            )

        if not decisions:
            break

        response = openai.responses.create(
            input=decisions,
            previous_response_id=response.id,
            extra_body=agent_reference,
        )

    outcome.answer = response.output_text
    return outcome


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("question")
    parser.add_argument(
        "--allow-writes",
        action="store_true",
        help="Approve tool calls that change infrastructure (stands in for a human approver).",
    )
    args = parser.parse_args()

    print(ask(args.question, allow_writes=args.allow_writes).as_json())


if __name__ == "__main__":
    main()
