#FROM ghcr.io/berriai/litellm:v1.81.14-stable
#FROM ghcr.io/berriai/litellm@sha256:1f16117e4a5707116729c3dea53505e5b2fabe7c63fe6ab02c046a9b42b222fe
FROM ghcr.io/berriai/litellm:v1.106.2@sha256:7294b90f868c5c38c99b83021c7ba46f9b439e95f8e32964c925c7d2563a03f7

#COPY config.yaml /app/config.yaml

# Fix LiteLLM tool_use delta chunk discarding bug (Issues #25321 / #24134)
#COPY patch_litellm.py /tmp/patch_litellm.py
#RUN /app/.venv/bin/python3 /tmp/patch_litellm.py && rm /tmp/patch_litellm.py
COPY apply_patch.py /tmp/apply_patch.py
COPY test_apply_patch.py /tmp/test_apply_patch.py
RUN /app/.venv/bin/python3 -m unittest discover -s /tmp -p 'test_apply_patch.py' -v \
    && /app/.venv/bin/python3 /tmp/apply_patch.py \
    && rm /tmp/apply_patch.py /tmp/test_apply_patch.py

EXPOSE 4000

ENTRYPOINT ["litellm", "--config", "/app/config.yaml", "--port", "4000"]
