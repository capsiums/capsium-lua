FROM openresty/openresty:alpine

# Install dependencies
RUN apk add --no-cache \
    git \
    build-base \
    lua5.1-dev \
    luarocks \
    zip \
    unzip

# Install Lua dependencies
RUN luarocks install lua-cjson && \
    luarocks install luafilesystem && \
    luarocks install brimworks-zip

# Create Capsium directories
RUN mkdir -p /var/lib/capsium/packages && \
    mkdir -p /var/lib/capsium/extracted && \
    mkdir -p /var/lib/capsium/static

# Copy Lua modules
COPY lua/capsium /etc/nginx/lua/capsium

# Copy Nginx configuration
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY nginx/conf.d /etc/nginx/conf.d

# Expose port
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]
