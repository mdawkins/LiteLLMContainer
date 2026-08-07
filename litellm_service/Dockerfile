FROM ghcr.io/berriai/litellm:v1.95.0@sha256:af806882b7a6ced41658db5b6a7e98ed7b9b51d03b935e0417bf1c8552d688af

COPY config.yaml /app/config.yaml

EXPOSE 4000

ENTRYPOINT ["litellm", "--config", "/app/config.yaml", "--port", "4000"]
