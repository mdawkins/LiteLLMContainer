FROM ghcr.io/berriai/litellm:main-stable

#COPY config.yaml /app/config.yaml

# Fix LiteLLM tool_use delta chunk discarding bug (Issues #25321 / #24134)
#COPY patch_litellm.py /tmp/patch_litellm.py
#RUN /app/.venv/bin/python3 /tmp/patch_litellm.py && rm /tmp/patch_litellm.py
COPY apply_patch.py /tmp/apply_patch.py
COPY test_apply_patch.py /tmp/test_apply_patch.py
RUN /app/.venv/bin/python3 -m unittest discover -s /tmp -p 'test_apply_patch.py' -v \
    && /app/.venv/bin/python3 /tmp/apply_patch.py \
    && rm /tmp/apply_patch.py /tmp/test_apply_patch.py

# Pre-call shim: adds an inert placeholder tool to Claude requests that carry
# tool history but no `tools` array (USAI rejects those with a toolConfig 400).
# Must sit next to config.yaml so `callbacks: tool_config_shim...` resolves.
COPY tool_config_shim.py /app/tool_config_shim.py
COPY test_tool_config_shim.py /tmp/test_tool_config_shim.py
RUN cd /app && PYTHONPATH=/app /app/.venv/bin/python3 -m unittest discover -s /tmp -p 'test_tool_config_shim.py' -v \
    && rm /tmp/test_tool_config_shim.py

EXPOSE 4000

ENTRYPOINT ["litellm", "--config", "/app/config.yaml", "--port", "4000"]
