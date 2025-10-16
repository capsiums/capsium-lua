ARG BASE_IMAGE=openresty/openresty:alpine-fat
FROM ${BASE_IMAGE}

# Install dependencies (alpine-fat already includes lua-cjson, luafilesystem)
RUN apk add --no-cache \
    luarocks \
    libzip-dev \
    zip \
    unzip

# Install additional Lua dependencies not in alpine-fat
RUN luarocks install luafilesystem && \
    luarocks install lua-zip

# Create Capsium directories and set permissions for nginx user (nobody)
RUN mkdir -p /var/lib/capsium/packages && \
    mkdir -p /var/lib/capsium/extracted && \
    mkdir -p /var/lib/capsium/static && \
    mkdir -p /var/log/nginx && \
    chown -R nobody:nobody /var/lib/capsium && \
    chown -R nobody:nobody /var/log/nginx

# Copy Lua modules
COPY lib/capsium /usr/local/openresty/luajit/share/lua/5.1/capsium
COPY lua/capsium /etc/nginx/lua/capsium

# Copy Nginx configuration
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY nginx/conf.d /etc/nginx/conf.d

# Expose port
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]
