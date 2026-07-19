-- Capsium Lua Library
-- MIME type detection (framework-agnostic, single source of truth)

local _M = {
  _VERSION = "0.2.0"
}

-- Extension to MIME type mapping.
-- JavaScript is text/javascript per RFC 9239.
local MIME_TYPES = {
  [".html"] = "text/html",
  [".htm"] = "text/html",
  [".css"] = "text/css",
  [".js"] = "text/javascript",
  [".mjs"] = "text/javascript",
  [".json"] = "application/json",
  [".map"] = "application/json",
  [".xml"] = "application/xml",
  [".txt"] = "text/plain",
  [".md"] = "text/markdown",
  [".csv"] = "text/csv",
  [".tsv"] = "text/tab-separated-values",
  [".yaml"] = "application/yaml",
  [".yml"] = "application/yaml",
  [".jpg"] = "image/jpeg",
  [".jpeg"] = "image/jpeg",
  [".png"] = "image/png",
  [".gif"] = "image/gif",
  [".svg"] = "image/svg+xml",
  [".webp"] = "image/webp",
  [".avif"] = "image/avif",
  [".pdf"] = "application/pdf",
  [".zip"] = "application/zip",
  [".cap"] = "application/vnd.capsium.package",
  [".ico"] = "image/x-icon",
  [".wasm"] = "application/wasm",
  [".woff"] = "font/woff",
  [".woff2"] = "font/woff2",
  [".ttf"] = "font/ttf",
  [".eot"] = "application/vnd.ms-fontobject",
  [".otf"] = "font/otf",
  [".mp4"] = "video/mp4",
  [".webm"] = "video/webm",
  [".mp3"] = "audio/mpeg",
  [".wav"] = "audio/wav"
}

-- Get MIME type for a file path based on its extension.
-- Returns nil when the extension is unknown.
function _M.type_for(file_path)
  if type(file_path) ~= "string" then
    return nil
  end

  local ext = file_path:match("%.([^%.]+)$")
  if ext then
    return MIME_TYPES["." .. ext:lower()]
  end
  return nil
end

return _M
