ARG BASE_IMAGE=openresty/openresty:alpine-fat
FROM ${BASE_IMAGE}

# Install dependencies
RUN apk add --no-cache \
    git \
    build-base \
    lua5.1-dev \
    luarocks \
    zip \
    unzip \
    zlib-dev \
    libzip-dev

# Install Lua dependencies
RUN luarocks-5.1 install lua-cjson && \
    luarocks-5.1 install luafilesystem && \
    luarocks-5.1 install lua-zlib && \
    luarocks-5.1 install lua-zip

# Create Capsium directories and set permissions for nginx user (nobody)
RUN mkdir -p /var/lib/capsium/packages && \
    mkdir -p /var/lib/capsium/extracted && \
    mkdir -p /var/lib/capsium/static && \
    mkdir -p /var/log/nginx && \
    chown -R nobody:nobody /var/lib/capsium && \
    chown -R nobody:nobody /var/log/nginx

# Copy Lua modules
COPY lua/capsium /etc/nginx/lua/capsium

# Copy Nginx configuration
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY nginx/conf.d /etc/nginx/conf.d

# Expose port
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]
