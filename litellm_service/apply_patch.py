"""Fail-closed source patch for LiteLLM's Anthropic streaming adapter.

When the pinned image digest changes, the build only continues if the exact
reviewed upstream block is still present or the exact local patch is already
present.  This prevents a textual patch from silently landing in changed code.
"""

from __future__ import annotations

import os
import sys


class PatchError(RuntimeError):
    pass


OLD_CODE = """        if block_type != self.current_content_block_type:
            self.current_content_block_type = block_type
            self.current_content_block_start = content_block_start
            return True

        # For parallel tool calls, we'll necessarily have a new content block
        # if we get a function name since it signals a new tool call
        if block_type == "tool_use":
            from typing import cast

            from litellm.types.llms.anthropic import ToolUseBlock

            tool_block = cast(ToolUseBlock, content_block_start)
            if tool_block.get("name"):
                self.current_content_block_type = block_type
                self.current_content_block_start = content_block_start
                return True

        return False"""

# The tagged source and some packaged wheels differ only by this blank line.
# Both variants were reviewed; no broader fuzzy/regex match is permitted.
OLD_CODE_COMPACT = OLD_CODE.replace(
    "            from litellm.types.llms.anthropic import ToolUseBlock\n\n            tool_block",
    "            from litellm.types.llms.anthropic import ToolUseBlock\n            tool_block",
)
OLD_CODES = (OLD_CODE, OLD_CODE_COMPACT)

NEW_CODE = """        if block_type == "tool_use":
            from typing import cast

            from litellm.types.llms.anthropic import ToolUseBlock

            tool_block = cast(ToolUseBlock, content_block_start)
            tool_id = tool_block.get("id")

            if block_type != self.current_content_block_type:
                self.current_content_block_type = block_type
                self.current_content_block_start = content_block_start
                self._active_tool_id = tool_id
                return True

            if tool_block.get("name") and tool_id:
                if tool_id != getattr(self, "_active_tool_id", None):
                    self._active_tool_id = tool_id
                    self.current_content_block_type = block_type
                    self.current_content_block_start = content_block_start
                    return True
                return False

        if block_type != self.current_content_block_type:
            self.current_content_block_type = block_type
            self.current_content_block_start = content_block_start
            return True

        return False"""

PATCH_MARKER = 'if tool_id != getattr(self, "_active_tool_id", None):'


def patch_content(content: str, filename: str) -> tuple[str, str]:
    matches = [(candidate, content.count(candidate)) for candidate in OLD_CODES]
    old_count = sum(count for _, count in matches)
    new_count = content.count(NEW_CODE)
    marker_count = content.count(PATCH_MARKER)

    if old_count == 1 and new_count == 0 and marker_count == 0:
        matched = next(candidate for candidate, count in matches if count == 1)
        patched = content.replace(matched, NEW_CODE, 1)
        compile(patched, filename, "exec")
        if any(candidate in patched for candidate in OLD_CODES) or patched.count(NEW_CODE) != 1:
            raise PatchError("post-patch contract failed")
        return patched, "applied"
    if old_count == 0 and new_count == 1 and marker_count == 1:
        compile(content, filename, "exec")
        return content, "already-applied"
    raise PatchError(
        "reviewed source contract not met "
        f"(old blocks={old_count}, patched blocks={new_count}, markers={marker_count}); "
        "review the new LiteLLM source before updating the image digest"
    )


def target_path() -> str:
    import litellm

    return os.path.join(
        litellm.__path__[0],
        "llms",
        "anthropic",
        "experimental_pass_through",
        "adapters",
        "streaming_iterator.py",
    )


def main() -> int:
    target = target_path()
    try:
        with open(target, encoding="utf-8") as handle:
            content = handle.read()
        patched, status = patch_content(content, target)
        if status == "applied":
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(patched)
        print(f"[PATCH SUCCESS] {status}: {target}")
        return 0
    except (OSError, PatchError, SyntaxError) as exc:
        print(f"[PATCH ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
