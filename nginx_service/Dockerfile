FROM docker.io/library/nginx:1.31.8-alpine3.24-slim@sha256:45d4ab2ffcf02e39468280840c608096a7f5f53fa2bf3b4b0c33b30d98ddbef4

# TLS certificates are generated and validated by stackctl.sh on the host.
# Keeping certificate lifecycle outside this image avoids requiring Alpine
# package-repository access during every build. The certificate/key are mounted
# at runtime from ./nginx_certs.

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
