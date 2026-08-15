FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && pip install --no-cache-dir "headroom-ai[proxy]==0.27.0" \
    && apt-get purge -y build-essential \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

EXPOSE 8787
ENV HEADROOM_TELEMETRY=off

# CRITICAL for Claude Code / User message compression:
ENV HEADROOM_COMPRESS_USER_MESSAGES=1

CMD ["headroom", "proxy", "--host", "0.0.0.0", "--port", "8787"]
