ARG BASE_IMAGE=openresty/openresty:alpine-fat
FROM ${BASE_IMAGE}

# Install system dependencies
RUN apk add --no-cache \
    luarocks \
    libzip-dev \
    zip \
    unzip

# Install Capsium via rockspec (includes all Lua dependencies)
COPY capsium-dev-1.rockspec /tmp/
COPY lib/ /tmp/lib/
RUN cd /tmp && luarocks make capsium-dev-1.rockspec && rm -rf /tmp/*

# Create Capsium directories and set permissions for nginx user (nobody)
RUN mkdir -p /var/lib/capsium/packages && \
    mkdir -p /var/lib/capsium/extracted && \
    mkdir -p /var/lib/capsium/static && \
    mkdir -p /var/log/nginx && \
    chown -R nobody:nobody /var/lib/capsium && \
    chown -R nobody:nobody /var/log/nginx

# Copy Nginx-specific Reactor layer (not in rockspec yet)
COPY lua/capsium /etc/nginx/lua/capsium

# Copy Nginx configuration
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY nginx/conf.d /etc/nginx/conf.d

# Expose port
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]
