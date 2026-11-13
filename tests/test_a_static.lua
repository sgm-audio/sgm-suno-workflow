--[[============================================================================
  test_a_static.lua — static verification against the official REAPER API.

  * every .lua file compiles under Lua 5.4
  * every reaper.<Name> call exists in the official API (tests/reaper_api_names.txt)
  * ReaPack headers are present and consistent with index.xml
============================================================================]]--

local harness = require("harness")

local SCRIPTS = {
  "SGM_SunoWorkflow_Bundle.lua",
  "Suno_01_MetadataOrganizer.lua",
  "Suno_02_TempoMapper.lua",
  "Suno_03_DynamicSplitter.lua",
  "Suno_04_LoudnessMaster.lua",
  "Suno_05_StemAligner.lua",
  "Various/SGM_Suno ZIP Importer.lua",
}

local function read_all(path)
  local f = assert(io.open(harness.ROOT .. "/" .. path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function api_names()
  local set = {}
  local f = assert(io.open(harness.ROOT .. "/tests/reaper_api_names.txt", "r"))
  for line in f:lines() do
    line = line:gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then set[line] = true end
  end
  f:close()
  return set
end

-- Names provided by extensions or the ReaScript host, not by reaper_plugin_functions.h.
local function is_extension_api(name)
  return name:match("^ImGui_") ~= nil
      or name:match("^gfx_") ~= nil
      or name:match("^SWS_") ~= nil
      or name:match("^CF_") ~= nil
end

return function(t)
  local api = api_names()

  t.group("static: syntax")
  for _, path in ipairs(SCRIPTS) do
    t.test("compiles: " .. path, function()
      local ok, err = harness.compile(path)
      t.ok(ok, "compiles under Lua 5.4: " .. tostring(err))
    end)
  end

  t.group("static: ReaScript API names")
  for _, path in ipairs(SCRIPTS) do
    t.test("API calls exist: " .. path, function()
      local src = read_all(path)
      -- Strip comments and long strings so doc text isn't scanned.
      local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
      local unknown, seen = {}, {}
      for name in code:gmatch("reaper%.([%a_][%w_]*)") do
        if not api[name] and not is_extension_api(name) and not seen[name] then
          seen[name] = true
          unknown[#unknown + 1] = name
        end
      end
      t.eq(#unknown, 0, "unknown REAPER API call(s): " .. table.concat(unknown, ", "))
    end)
  end

  t.group("static: ReaPack metadata")
  for _, path in ipairs(SCRIPTS) do
    t.test("header: " .. path, function()
      local src = read_all(path)
      local head = src:sub(1, 2000)
      if path:find("Bundle") then
        t.ok(head:find("@metapackage", 1, true) ~= nil, "has @metapackage")
        t.ok(head:find("@provides [main]", 1, true) ~= nil, "has @provides")
      else
        t.ok(head:find("@description", 1, true) ~= nil, "has @description")
        t.ok(head:find("@version", 1, true) ~= nil, "has @version")
      end
    end)
  end

  t.test("every package name carries a .lua extension", function()
    -- ReaPack installs a source under its `file` attribute, or under the
    -- package `name` when the attribute is absent (Source::file() falls back
    -- to the package name). Without the extension ReaPER cannot load the file.
    local index = read_all("index.xml")
    local bad = {}
    for name in index:gmatch('<reapack name="([^"]+)"') do
      if not name:match("%.lua$") then bad[#bad + 1] = name end
    end
    t.eq(#bad, 0, "packages without a .lua name: " .. table.concat(bad, ", "))
  end)

  t.test("bundle @provides paths are declared as package sources", function()
    local index = read_all("index.xml")
    local bundle = read_all("SGM_SunoWorkflow_Bundle.lua")

    local provides = {}
    for path in bundle:gmatch("@provides %[main%]%s*([^\n]+)") do
      provides[#provides + 1] = path:gsub("%s+$", "")
    end
    t.ok(#provides > 0, "bundle declares at least one @provides entry")

    local start = index:find('name="SGM_SunoWorkflow_Bundle.lua"')
    t.ok(start ~= nil, "bundle package is present in index.xml")
    if not start then return end
    local stop = index:find("</reapack>", start) or #index
    local block = index:sub(start, stop)

    local sources = {}
    for f in block:gmatch('file="([^"]+)"') do sources[f] = true end

    local missing = {}
    for _, p in ipairs(provides) do
      if not sources[p] then missing[#missing + 1] = p end
    end
    t.eq(#missing, 0,
         "provided files with no matching <source file=...>: " .. table.concat(missing, ", "))
  end)

  t.test("index.xml versions match script headers", function()
    local index = read_all("index.xml")
    local problems = {}
    -- <reapack name="..."> ... <version name="x" ...> <source ...>URL</source>
    for body in index:gmatch("<reapack name=\"([^\"]*)\"(.-)</reapack>") do end
    for name, body in index:gmatch("<reapack name=\"([^\"]*)\"(.-)</reapack>") do
      local ver = body:match("<version name=\"([^\"]*)\"")
      local url = body:match("<source main=\"main\">([^<]*)</source>")
      local file = url and url:match("/([^/]+)$")
      if file then
        file = file:gsub("%%20", " ")
        local found = nil
        for _, p in ipairs(SCRIPTS) do
          if p:sub(-#file) == file then found = p end
        end
        if not found then
          problems[#problems + 1] = ("%s -> %s (no such file)"):format(name, file)
        else
          local src = read_all(found)
          local hv = src:match("@version%s+([%d%.]+)")
          if hv ~= ver then
            problems[#problems + 1] = ("%s: index %s vs file %s"):format(name, tostring(ver), tostring(hv))
          end
        end
      end
    end
    t.eq(#problems, 0, "version mismatches: " .. table.concat(problems, "; "))
  end)
end
