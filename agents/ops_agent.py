"""The ops agent, defined as code.

Running this file creates a new immutable version of the agent in the Foundry
project. The agent itself is configuration: a model, instructions, and one
MCP tool server. Nothing here runs at request time.
"""

import os

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import MCPTool, PromptAgentDefinition
from azure.identity import DefaultAzureCredential

AGENT_NAME = os.environ.get("AGENT_NAME", "azure-ops-copilot")

# Read-only tools the client may approve automatically. Anything absent here
# needs a human, which is why the list lives next to the agent definition
# rather than being inferred at run time.
READ_ONLY_TOOLS = ("list_resources", "container_app_status", "query_logs")

INSTRUCTIONS = """
You are an Azure operations assistant for a single lab resource group.

How to work:
- Start from evidence. Call list_resources to see what exists before naming
  any resource, and container_app_status before judging health.
- When you need logs, write a Kusto query for query_logs. The container app
  tables are ContainerAppConsoleLogs_CL and ContainerAppSystemLogs_CL.
  If a query fails, read the error and correct it once.
- Restarting an app interrupts live requests. Propose it only when the
  evidence supports it, say plainly what it will affect, and expect the
  request to be approved or refused by a human.
- If a request is refused, accept it and suggest what to investigate instead.

How to answer:
- Lead with the finding, then the evidence that supports it.
- Name the exact resources and figures you observed. Do not estimate.
- If the tools did not return enough to answer, say what is missing.
Keep answers under 200 words.
""".strip()


def main() -> None:
    project = AIProjectClient(
        endpoint=os.environ["PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )

    tools = [
        MCPTool(
            server_label="azure-ops",
            server_url=os.environ["MCP_ENDPOINT"],
            # Every tool call comes back for approval; the client applies the
            # policy. Approval is never decided by the model.
            require_approval="always",
            project_connection_id=os.environ["MCP_CONNECTION_NAME"],
        )
    ]

    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=os.environ["MODEL_DEPLOYMENT"],
            instructions=INSTRUCTIONS,
            tools=tools,
        ),
    )
    print(f"agent={agent.name} version={agent.version} id={agent.id}")


if __name__ == "__main__":
    main()
