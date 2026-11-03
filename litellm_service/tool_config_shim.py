"""LiteLLM pre-call shim for USAI's Claude routes.

USAI's Claude upstreams (Bedrock Converse behind an OpenAI-style API) reject any
request whose history contains tool-use / tool-result blocks unless a ``tools``
array is also present:

    400 The toolConfig field must be defined when using toolUse and toolResult
        content blocks.

Claude Code's built-in Stop-hook evaluator (and some other internal helpers)
send exactly that shape: tool history, no tools.  This shim adds one inert
placeholder tool, plus tool_choice "none", for Claude-model requests that need
it.  Requests that already carry tools, have no tool history, or target
non-Claude models are left untouched.

Handles both request shapes the proxy sees:
  * OpenAI chat completions (``/v1/chat/completions``)
  * Anthropic messages      (``/v1/messages``)
"""

from __future__ import annotations

from typing import Any

try:  # LiteLLM is only present inside the proxy image.
    from litellm.integrations.custom_logger import CustomLogger
except ImportError:  # pragma: no cover - lets unit tests run without LiteLLM
    class CustomLogger:  # type: ignore[no-redef]
        pass

PLACEHOLDER_NAME = "noop_placeholder"
PLACEHOLDER_DESCRIPTION = (
    "Inert placeholder required by the upstream API. Never call this tool."
)
CLAUDE_MARKERS = ("claude", "anthropic", "haiku", "sonnet", "opus")


def _is_claude_model(model: Any) -> bool:
    return isinstance(model, str) and any(m in model.lower() for m in CLAUDE_MARKERS)


def _has_tool_history(messages: Any) -> bool:
    if not isinstance(messages, list):
        return False
    for message in messages:
        if not isinstance(message, dict):
            continue
        if message.get("role") == "tool" or message.get("tool_calls"):
            return True
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") in (
                    "tool_use",
                    "tool_result",
                ):
                    return True
    return False


def _is_anthropic_shape(data: dict, call_type: str | None) -> bool:
    if call_type in ("anthropic_messages", "pass_through_endpoint"):
        return True
    # Anthropic requests carry a top-level ``system`` or content-block tool use.
    for message in data.get("messages") or []:
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, list) and any(
            isinstance(b, dict) and b.get("type") in ("tool_use", "tool_result")
            for b in content
        ):
            return True
    return "system" in data and "tool_calls" not in str(data.get("messages"))


def apply_shim(data: dict, call_type: str | None = None) -> bool:
    """Mutate ``data`` in place. Returns True when a placeholder was added."""
    if not isinstance(data, dict):
        return False
    if data.get("tools"):
        return False
    if not _is_claude_model(data.get("model")):
        return False
    if not _has_tool_history(data.get("messages")):
        return False

    if _is_anthropic_shape(data, call_type):
        data["tools"] = [
            {
                "name": PLACEHOLDER_NAME,
                "description": PLACEHOLDER_DESCRIPTION,
                "input_schema": {"type": "object", "properties": {}},
            }
        ]
        data.setdefault("tool_choice", {"type": "none"})
    else:
        data["tools"] = [
            {
                "type": "function",
                "function": {
                    "name": PLACEHOLDER_NAME,
                    "description": PLACEHOLDER_DESCRIPTION,
                    "parameters": {"type": "object", "properties": {}},
                },
            }
        ]
        data.setdefault("tool_choice", "none")
    return True


class ToolConfigShim(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        apply_shim(data, call_type)
        return data


proxy_handler_instance = ToolConfigShim()
