-- In-memory zip adapter for unit tests (implements the zip_adapter
-- contract: open, close, list_files, read_file — called dot-style:
-- zip.open(path), zip.list_files(zfile), zip.read_file(zfile, name))

local MockZip = {}

-- archives: { [path] = { files = { {name=..., content=..., fail_read=...},
--                                 ... },
--                        fail_open = bool, fail_list = bool } }
function MockZip.new(archives)
  local self = { archives = archives or {} }

  function self.open(path)
    local archive = self.archives[path]
    if not archive or archive.fail_open then
      return nil, "cannot open zip archive: " .. tostring(path)
    end

    return {
      archive = archive,
      closed = false
    }
  end

  function self.close(zfile)
    if zfile then
      zfile.closed = true
    end
    return true
  end

  function self.list_files(zfile)
    if not zfile or zfile.closed or zfile.archive.fail_list then
      return nil, "invalid zip handle"
    end

    local names = {}
    for _, entry in ipairs(zfile.archive.files) do
      table.insert(names, entry.name)
    end
    return names
  end

  function self.read_file(zfile, name)
    if not zfile or zfile.closed then
      return nil, "invalid zip handle"
    end

    for _, entry in ipairs(zfile.archive.files) do
      if entry.name == name then
        if entry.fail_read then
          return nil, "cannot read entry: " .. name
        end
        return entry.content
      end
    end

    return nil, "no such entry: " .. tostring(name)
  end

  return self
end

return MockZip
