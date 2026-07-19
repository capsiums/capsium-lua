package = "capsium"
version = "0.2.0-1"

source = {
   url = "git+https://github.com/capsiums/capsium-lua.git"
}

description = {
   summary = "Framework-agnostic Lua library for serving Capsium packages",
   detailed = [[
      Capsium is a framework-agnostic Lua library that provides Package
      manipulation and HTTP serving (Reactor) for Capsium packages (.cap files).

      Features:
      - Package layer for .cap file manipulation (canonical + legacy schemas)
      - SHA-256 integrity verification (security.json, reject on mismatch)
      - Manifest-driven route auto-generation
      - Reactor layer for HTTP serving with introspection API
      - Nginx/OpenResty adapter included
      - Multi-package deployment support
      - Flexible routing and configuration
   ]],
   homepage = "https://github.com/capsiums/capsium-lua",
   license = "MIT"
}

dependencies = {
   "lua >= 5.1",
   "luafilesystem >= 1.8.0",
   "lua-cjson >= 2.1.0",
   "lua-zip >= 0.2",
   "lua-resty-openssl >= 1.3"
}

build = {
   type = "builtin",
   modules = {
      -- Core utilities
      ["capsium.utils"] = "lib/capsium/utils.lua",
      ["capsium.mime"] = "lib/capsium/mime.lua",
      ["capsium.csv"] = "lib/capsium/csv.lua",
      ["capsium.crypto"] = "lib/capsium/crypto.lua",

      -- Reactor core
      ["capsium.reactor"] = "lib/capsium/reactor.lua",

      -- Package layer
      ["capsium.package.package"] = "lib/capsium/package/package.lua",
      ["capsium.package.extractor"] = "lib/capsium/package/extractor.lua",
      ["capsium.package.decrypter"] = "lib/capsium/package/decrypter.lua",
      ["capsium.package.router"] = "lib/capsium/package/router.lua",
      ["capsium.package.security"] = "lib/capsium/package/security.lua",

      -- Adapters
      ["capsium.adapters.nginx"] = "lib/capsium/adapters/nginx.lua",
      ["capsium.adapters.hash"] = "lib/capsium/adapters/hash.lua"
   }
}
