-- In-memory fs adapter for unit tests (implements the fs_adapter contract:
-- file_exists, dir_exists, list_dir, read_file, write_file, mkdir_p,
-- get_mtime, rename, remove)
--
-- Adapter functions are called dot-style by the core (fs.read_file(path));
-- the methods here also tolerate colon-style calls from the specs.

local MockFs = {}

-- Strip the implicit self argument when called colon-style.
local function args(...)
  local a = { ... }
  if type(a[1]) == "table" then
    table.remove(a, 1)
  end
  return a
end

function MockFs.new(tree)
  local files = {} -- path -> content
  local dirs = { [""] = true }
  local mtimes = {} -- path -> mtime

  local fs = {}

  local function touch(path)
    mtimes[path] = os.time()
  end

  local function register_parents(path)
    local dir = path:match("^(.*)/[^/]+$")
    while dir and dir ~= "" do
      dirs[dir] = true
      dir = dir:match("^(.*)/[^/]+$")
    end
  end

  function fs.file_exists(...)
    return files[args(...)[1]] ~= nil
  end

  function fs.dir_exists(...)
    return dirs[args(...)[1]] == true
  end

  function fs.list_dir(...)
    local path = args(...)[1]
    if not dirs[path] then
      return nil
    end

    local seen = {}
    local entries = {}
    local prefix = path == "" and "" or (path .. "/")

    local function add(container)
      for p in pairs(container) do
        if p:sub(1, #prefix) == prefix then
          local rest = p:sub(#prefix + 1)
          if rest ~= "" and not rest:find("/") and not seen[rest] then
            seen[rest] = true
            table.insert(entries, rest)
          end
        end
      end
    end

    add(dirs)
    add(files)
    table.sort(entries)
    return entries
  end

  function fs.read_file(...)
    local path = args(...)[1]
    local content = files[path]
    if content == nil then
      return nil, "no such file: " .. tostring(path)
    end
    return content
  end

  function fs.write_file(...)
    local a = args(...)
    local path, content = a[1], a[2]
    files[path] = content
    register_parents(path)
    touch(path)
    return true
  end

  function fs.mkdir_p(...)
    local path = args(...)[1]
    dirs[path] = true
    register_parents(path .. "/x")
    touch(path)
    return true
  end

  function fs.get_mtime(...)
    return mtimes[args(...)[1]]
  end

  function fs.rename(...)
    local a = args(...)
    local src, dst = a[1], a[2]

    -- Move a single file
    if files[src] ~= nil then
      files[dst] = files[src]
      files[src] = nil
      mtimes[dst] = mtimes[src]
      mtimes[src] = nil
      register_parents(dst)
      return true
    end

    -- Move a directory tree
    if not dirs[src] then
      return false, "no such file or directory: " .. tostring(src)
    end

    local prefix = src .. "/"
    local moved = {}
    for file, content in pairs(files) do
      if file:sub(1, #prefix) == prefix then
        moved[file] = content
      end
    end
    for file, content in pairs(moved) do
      files[file] = nil
      local target = dst .. "/" .. file:sub(#prefix + 1)
      files[target] = content
      mtimes[target] = os.time()
    end

    local moved_dirs = {}
    for dir in pairs(dirs) do
      if dir == src or dir:sub(1, #prefix) == prefix then
        table.insert(moved_dirs, dir)
      end
    end
    for _, dir in ipairs(moved_dirs) do
      dirs[dir] = nil
      local suffix = dir == src and "" or ("/" .. dir:sub(#prefix + 1))
      dirs[dst .. suffix] = true
    end
    register_parents(dst .. "/x")
    touch(dst)

    return true
  end

  function fs.remove(...)
    local path = args(...)[1]

    if files[path] ~= nil then
      files[path] = nil
      mtimes[path] = nil
      return true
    end

    if dirs[path] then
      local prefix = path .. "/"
      for file in pairs(files) do
        if file:sub(1, #prefix) == prefix then
          return false, "directory not empty: " .. path
        end
      end
      for dir in pairs(dirs) do
        if dir ~= path and dir:sub(1, #prefix) == prefix then
          return false, "directory not empty: " .. path
        end
      end
      dirs[path] = nil
      mtimes[path] = nil
      return true
    end

    return false, "no such file or directory: " .. tostring(path)
  end

  -- Seed the initial tree
  for path, content in pairs(tree or {}) do
    fs.write_file(path, content)
  end

  return fs
end

return MockFs
