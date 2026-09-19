FROM docker.io/library/nginx:1.31.5-alpine3.24@sha256:72ba65eb42c10344912a84ff42408db7d34f2feb642204570ab8fc5ffd29f1d3

# The entrypoint validates and creates the persisted self-signed certificate.
RUN apk add --no-cache openssl

# Pre-create nginx's cache/temp dirs so the master process (running without
# CAP_CHOWN due to cap_drop: ALL) doesn't try to chown them at startup —
# nginx only chowns a temp path if it has to create it fresh.
RUN mkdir -p /var/cache/nginx/client_temp \
             /var/cache/nginx/proxy_temp \
             /var/cache/nginx/fastcgi_temp \
             /var/cache/nginx/uwsgi_temp \
             /var/cache/nginx/scgi_temp \
    && chown -R nginx:nginx /var/cache/nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh

# Make the script executable
RUN chmod +x /entrypoint.sh

EXPOSE 80 443

# Tell Docker to run the script when the container starts
ENTRYPOINT ["/entrypoint.sh"]
