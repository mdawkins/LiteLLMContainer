import os
import sys
import litellm

litellm_path = litellm.__path__[0]
target_file = os.path.join(
    litellm_path,
    "llms",
    "anthropic",
    "experimental_pass_through",
    "adapters",
    "streaming_iterator.py",
)

with open(target_file, "r", encoding="utf-8") as f:
    content = f.read()

old_code = """        if block_type != self.current_content_block_type:
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

new_code = """        if block_type == "tool_use":
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

if old_code in content:
    patched = content.replace(old_code, new_code, 1)
    compile(patched, target_file, "exec")
    with open(target_file, "w", encoding="utf-8") as f:
        f.write(patched)
    print("[PATCH SUCCESS] Applied surgical patch to streaming_iterator.py")
elif "self._active_tool_id = tool_id" in content:
    print("[PATCH SUCCESS] File is already patched!")
else:
    print("[PATCH ERROR] Target block not found in streaming_iterator.py!")
    sys.exit(1)
