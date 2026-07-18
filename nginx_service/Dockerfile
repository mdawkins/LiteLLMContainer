FROM docker.io/library/nginx:alpine@sha256:7068961d45b07b2af510ac002e9daa63a1d3eba2111202d6768798690800fffd

RUN apk add --no-cache openssl

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh

# Make the script executable
RUN chmod +x /entrypoint.sh

EXPOSE 80 443

# Tell Docker to run the script when the container starts
ENTRYPOINT ["/entrypoint.sh"]