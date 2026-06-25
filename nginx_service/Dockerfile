FROM nginx:alpine

RUN apk add --no-cache openssl

COPY nginx.conf /etc/nginx/nginx.conf

RUN mkdir -p /etc/nginx/certs && \
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/certs/proxy.key \
        -out /etc/nginx/certs/proxy.crt \
        -subj "/CN=localhost"

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
