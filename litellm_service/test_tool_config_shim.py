import unittest

import tool_config_shim as shim

OPENAI_HIST = [
    {"role": "user", "content": "hi"},
    {
        "role": "assistant",
        "content": None,
        "tool_calls": [
            {"id": "c1", "type": "function", "function": {"name": "Read", "arguments": "{}"}}
        ],
    },
    {"role": "tool", "tool_call_id": "c1", "content": "ok"},
    {"role": "user", "content": "done?"},
]
ANTHROPIC_HIST = [
    {"role": "user", "content": "hi"},
    {"role": "assistant", "content": [{"type": "tool_use", "id": "c1", "name": "Read", "input": {}}]},
    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "c1", "content": "ok"}]},
]


class ShimTests(unittest.TestCase):
    def test_openai_shape_gets_placeholder(self):
        d = {"model": "openai/claude-haiku-5.5", "messages": list(OPENAI_HIST)}
        self.assertTrue(shim.apply_shim(d, "acompletion"))
        self.assertEqual(d["tools"][0]["function"]["name"], shim.PLACEHOLDER_NAME)
        self.assertEqual(d["tool_choice"], "none")

    def test_anthropic_shape_gets_placeholder(self):
        d = {"model": "openai/claude-sonnet-5.5", "messages": list(ANTHROPIC_HIST)}
        self.assertTrue(shim.apply_shim(d, "anthropic_messages"))
        self.assertIn("input_schema", d["tools"][0])
        self.assertEqual(d["tool_choice"], {"type": "none"})

    def test_anthropic_shape_detected_without_call_type(self):
        d = {"model": "claude-opus-5.5", "messages": list(ANTHROPIC_HIST)}
        self.assertTrue(shim.apply_shim(d, None))
        self.assertIn("input_schema", d["tools"][0])

    def test_existing_tools_untouched(self):
        tools = [{"type": "function", "function": {"name": "x", "parameters": {}}}]
        d = {"model": "claude-x", "messages": list(OPENAI_HIST), "tools": tools}
        self.assertFalse(shim.apply_shim(d))
        self.assertIs(d["tools"], tools)
        self.assertNotIn("tool_choice", d)

    def test_no_tool_history_untouched(self):
        d = {"model": "claude-x", "messages": [{"role": "user", "content": "hi"}]}
        self.assertFalse(shim.apply_shim(d))
        self.assertNotIn("tools", d)

    def test_non_claude_model_untouched(self):
        d = {"model": "openai/gpt-5.6-luna", "messages": list(OPENAI_HIST)}
        self.assertFalse(shim.apply_shim(d))
        self.assertNotIn("tools", d)

    def test_existing_tool_choice_preserved(self):
        d = {"model": "claude-x", "messages": list(OPENAI_HIST), "tool_choice": "auto"}
        shim.apply_shim(d)
        self.assertEqual(d["tool_choice"], "auto")

    def test_hook_returns_data(self):
        import asyncio

        d = {"model": "claude-x", "messages": list(OPENAI_HIST)}
        out = asyncio.run(shim.proxy_handler_instance.async_pre_call_hook(None, None, d, "acompletion"))
        self.assertIs(out, d)
        self.assertTrue(out["tools"])


if __name__ == "__main__":
    unittest.main()
