-- Capsium Lua Library
-- Minimal semver comparison and range matching (framework-agnostic)
--
-- Port of @capsium/core semver.ts (ARCHITECTURE.md section 4a needs
-- "newest satisfying version" for dependency resolution). Supported range
-- forms (space-separated AND): exact (1.2.3), wildcards (1.2.x, 1.x),
-- comparators (>=, >, <=, <, =), caret (^1.2.3) and tilde (~1.2.3).
-- Pre-release/build suffixes compare by the numeric triple only
-- (documented simplification). "*" / "x" match any version (the legacy
-- dependency normalization emits "*" for missing ranges).

local _M = {
  _VERSION = "0.4.0"
}

-- Parse "1.2.3" (optional leading v, optional pre-release/build suffix).
-- Returns { major, minor, patch } | nil.
function _M.parse(version)
  if type(version) ~= "string" then
    return nil
  end

  local major, minor, patch, rest = version:match(
    "^%s*v?(%d+)%.(%d+)%.(%d+)(.-)%s*$")
  if not major then
    return nil
  end
  -- Only pre-release (-...) / build (+...) suffixes may follow the triple
  if rest ~= "" and not rest:match("^[%-%+]") then
    return nil
  end

  return {
    major = tonumber(major),
    minor = tonumber(minor),
    patch = tonumber(patch)
  }
end

-- -1/0/1 comparison of two parsed version tables.
local function compare_parsed(a, b)
  for _, key in ipairs({ "major", "minor", "patch" }) do
    if a[key] ~= b[key] then
      return a[key] < b[key] and -1 or 1
    end
  end
  return 0
end

-- -1/0/1 comparison of two version strings; nil, err on non-semver input.
function _M.compare(a, b)
  local pa, pb = _M.parse(a), _M.parse(b)
  if not pa or not pb then
    return nil, "cannot compare non-semver: " .. tostring(a) .. " vs " ..
                tostring(b)
  end
  return compare_parsed(pa, pb)
end

-- Wildcard/partial forms: 1, 1.x, 1.2, 1.2.x, =1.2.x, v1.x
-- (a bare "1.2" means 1.2.x — any patch)
local function match_wildcard(version, comparator)
  if comparator:find("^[><~%^]") then
    return nil
  end

  local wmajor, wminor, wpatch = comparator:match(
    "^[=v]?(%d+)%.?([%dxX%*]-)%.?([%dxX%*]-)$")
  if not wmajor then
    return nil
  end

  local minor_wild = wminor == "" or wminor:match("^[xX%*]$") ~= nil
  local patch_wild = wpatch == "" or wpatch:match("^[xX%*]$") ~= nil
  if not minor_wild and not patch_wild and wpatch ~= "" then
    return nil -- full exact triple: handled by the comparator branch
  end

  if version.major ~= tonumber(wmajor) then
    return false
  end
  if not minor_wild and version.minor ~= tonumber(wminor) then
    return false
  end
  return true
end

-- Match one comparator against a parsed version.
local function matches_comparator(version, comparator)
  comparator = comparator:match("^%s*(.-)%s*$")

  local wildcard = match_wildcard(version, comparator)
  if wildcard ~= nil then
    return wildcard
  end

  -- Comparator forms: >=, >, <=, <, =, ^, ~ (or bare exact version)
  local op = "="
  local rest = comparator
  local prefix = comparator:match("^([><~%^]=?)") or comparator:match("^(=)")
  if prefix then
    op = prefix
    rest = comparator:sub(#prefix + 1)
  end

  local tmajor, tminor, tpatch, suffix = rest:match(
    "^%s*v?(%d+)%.(%d+)%.(%d+)(.-)%s*$")
  if not tmajor then
    return false
  end
  if suffix ~= "" and not suffix:match("^[%-%+]") then
    return false
  end

  local target = {
    major = tonumber(tmajor),
    minor = tonumber(tminor),
    patch = tonumber(tpatch)
  }
  local cmp = compare_parsed(version, target)

  if op == "=" then
    return cmp == 0
  elseif op == ">" then
    return cmp > 0
  elseif op == ">=" then
    return cmp >= 0
  elseif op == "<" then
    return cmp < 0
  elseif op == "<=" then
    return cmp <= 0
  elseif op == "~" then
    return version.major == target.major
           and version.minor == target.minor and cmp >= 0
  elseif op == "^" then
    if cmp < 0 then
      return false
    end
    if target.major > 0 then
      return version.major == target.major
    end
    if target.minor > 0 then
      return version.major == 0 and version.minor == target.minor
    end
    return version.major == 0 and version.minor == 0
           and version.patch == target.patch
  end

  return false
end

-- True when `version` satisfies every comparator in `range` (AND).
function _M.satisfies(version, range)
  local parsed = _M.parse(version)
  if not parsed or type(range) ~= "string" then
    return false
  end

  range = range:match("^%s*(.-)%s*$")
  if range == "*" or range:lower() == "x" then
    return true
  end

  local any = false
  for comparator in range:gmatch("%S+") do
    any = true
    if not matches_comparator(parsed, comparator) then
      return false
    end
  end

  return any
end

-- The newest version in `versions` (array) satisfying `range`, or nil.
function _M.newest_satisfying(versions, range)
  local best = nil

  for _, version in ipairs(versions or {}) do
    if _M.satisfies(version, range) then
      if not best or compare_parsed(_M.parse(version),
                                    _M.parse(best)) > 0 then
        best = version
      end
    end
  end

  return best
end

return _M
