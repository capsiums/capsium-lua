std = "luajit"
cache = true

files["lib/capsium/adapters/nginx.lua"] = {
  globals = {"ngx"}
}

ignore = {
  "212", -- Unused argument
  "213", -- Unused loop variable
}

exclude_files = {
  "spec/",
  ".luarocks/",
  ".rocks/",
}
