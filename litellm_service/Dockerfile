FROM ghcr.io/berriai/litellm:main-latest

COPY config.yaml /app/config.yaml

EXPOSE 4000

ENTRYPOINT ["litellm", "--config", "/app/config.yaml", "--port", "4000"]
