std = "luajit"
cache = true

ignore = {
  "212", -- Unused argument
  "213", -- Unused loop variable
}

exclude_files = {
  "spec/",
  ".luarocks/",
  ".rocks/",
}

files["lib/capsium/adapters/nginx.lua"] = {
  globals = {"ngx"}
}

files["lua/**"] = {
  globals = {"ngx"}
}

files["test/**"] = {
  globals = {
    "describe", "insulate", "expose", "it", "pending",
    "before_each", "after_each", "setup", "teardown",
    "assert", "spy", "mock", "stub", "finally"
  }
}
