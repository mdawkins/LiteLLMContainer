FROM ghcr.io/berriai/litellm:v1.92.0@sha256:9ef6f45bc0104940571765e610c52a1d761b5ec85efcd193795281086ee61277

COPY config.yaml /app/config.yaml

EXPOSE 4000

ENTRYPOINT ["litellm", "--config", "/app/config.yaml", "--port", "4000"]
