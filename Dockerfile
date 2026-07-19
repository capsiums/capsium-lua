ARG BASE_IMAGE=openresty/openresty:1.27.1.2-12-alpine-fat
FROM ${BASE_IMAGE}

# Install system dependencies
RUN apk add --no-cache \
    luarocks \
    libzip-dev \
    zip \
    unzip

# lua-resty-openssl (FFI) resolves OpenSSL symbols from the global namespace.
# Inside nginx workers they are already there (nginx links libcrypto); under
# plain LuaJIT (busted) its loader needs libcrypto.so/libssl.so path names —
# symlink them to the image's own OpenSSL 3 libraries. No openssl binary is
# needed (and `openssl enc` could not do AES-GCM anyway).
RUN ln -sf /usr/local/openresty/openssl3/lib/libcrypto.so.3 /usr/lib/libcrypto.so && \
    ln -sf /usr/local/openresty/openssl3/lib/libssl.so.3 /usr/lib/libssl.so

# Install Capsium via rockspec (includes all Lua dependencies)
COPY capsium-0.2.0-1.rockspec /tmp/
COPY lib/ /tmp/lib/
RUN cd /tmp && luarocks make capsium-0.2.0-1.rockspec && rm -rf /tmp/*

# Create Capsium directories and set permissions for nginx user (nobody)
RUN mkdir -p /var/lib/capsium/packages && \
    mkdir -p /var/lib/capsium/extracted && \
    mkdir -p /var/lib/capsium/static && \
    mkdir -p /var/log/nginx && \
    chown -R nobody:nobody /var/lib/capsium && \
    chown -R nobody:nobody /var/log/nginx

# Copy Nginx-specific glue layer (capsium entry + config loading)
COPY lua/capsium /etc/nginx/lua/capsium

# Copy Nginx configuration
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY nginx/conf.d /etc/nginx/conf.d

# Expose port
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]
