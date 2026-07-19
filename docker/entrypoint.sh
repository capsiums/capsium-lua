#!/bin/sh
# Capsium container entrypoint.
#
# Renders the nginx `resolver` directive from the container's own
# resolv.conf so Lua cosocket HTTP clients (OAuth2 token/userinfo calls,
# ARCHITECTURE.md section 4b) resolve upstreams on any Docker network —
# Docker's embedded 127.0.0.11 on Linux, the VM DNS proxy on Docker
# Desktop / OrbStack. nginx does not read /etc/resolv.conf itself.

RESOLVER_CONF=/tmp/capsium-resolver.conf

nameserver=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf)
if [ -n "$nameserver" ]; then
    echo "resolver $nameserver valid=10s ipv6=off;" > "$RESOLVER_CONF"
else
    : > "$RESOLVER_CONF"
fi

exec nginx -g 'daemon off;'
