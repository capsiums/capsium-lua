package = "capsium"
version = "dev-1"

source = {
   url = "git://github.com/capsiums/capsium-lua.git"
}

description = {
   summary = "Framework-agnostic Lua library for serving Capsium packages",
   detailed = [[
      Capsium is a framework-agnostic Lua library that provides Package
      manipulation and HTTP serving (Reactor) for Capsium packages (.cap files).

      Features:
      - Package layer for .cap file manipulation
      - Reactor layer for HTTP serving
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
   "lua-zip >= 0.2"
}

build = {
   type = "builtin",
   modules = {
      -- Core utilities
      ["capsium.utils"] = "lib/capsium/utils.lua",

      -- Package layer
      ["capsium.package.extractor"] = "lib/capsium/package/extractor.lua",
      ["capsium.package.package"] = "lib/capsium/package/package.lua",

      -- Adapters
      ["capsium.adapters.nginx"] = "lib/capsium/adapters/nginx.lua"
   }
}
