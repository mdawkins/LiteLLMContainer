#FROM ghcr.io/berriai/litellm:v1.81.14-stable
#FROM ghcr.io/berriai/litellm@sha256:1f16117e4a5707116729c3dea53505e5b2fabe7c63fe6ab02c046a9b42b222fe
FROM ghcr.io/berriai/litellm:v1.101.0@sha256:d295634e09c648dcdb72c4cc2dd226f5fb87823a73e88cbbed6f205e4deb044b

#COPY config.yaml /app/config.yaml

# Fix LiteLLM tool_use delta chunk discarding bug (Issues #25321 / #24134)
#COPY patch_litellm.py /tmp/patch_litellm.py
#RUN /app/.venv/bin/python3 /tmp/patch_litellm.py && rm /tmp/patch_litellm.py
COPY apply_patch.py /tmp/apply_patch.py
COPY test_apply_patch.py /tmp/test_apply_patch.py
RUN /app/.venv/bin/python3 -m unittest -v /tmp/test_apply_patch.py \
    && /app/.venv/bin/python3 /tmp/apply_patch.py \
    && rm /tmp/apply_patch.py /tmp/test_apply_patch.py

EXPOSE 4000

ENTRYPOINT ["litellm", "--config", "/app/config.yaml", "--port", "4000"]
