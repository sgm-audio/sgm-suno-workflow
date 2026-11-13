--[[============================================================================
  test_zip_importer.lua — Various/SGM_Suno ZIP Importer.lua

  The extraction shell commands are simulated: io.popen("unzip -Z1 …") returns
  the member list, os.execute('unzip … -d "DIR"') materialises the members, and
  PCM_Source_CreateFromFile resolves the registered signals.
============================================================================]]--

local harness = require("harness")

local SCRIPT = "Various/SGM_Suno ZIP Importer.lua"
local ZIP    = "/home/u/Song One_abc123.zip"
local TMP    = "/tmp/suno_Song_One_abc123_000000"

local INFO_JSON = table.concat({
  '{',
  '  "id": "abc123def456",',
  '  "title": "My Song",',
  '  "tags": "pop, synthwave",',
  '  "prompt": "[Verse]\\nhello there\\n[Chorus]\\nworld"',
  '}',
})

-- Register a ZIP whose extraction produces `members` and whose audio decodes
-- to a 4-second stereo source.
local function make_zip(P, members, audio_len)
  local names = {}
  P.zip_contents = {}
  P.sources = P.sources or {}
  for _, m in ipairs(members) do
    names[#names + 1] = m.name
    P.zip_contents[#P.zip_contents + 1] = { name = m.name, data = m.data or "" }
    if m.name:lower():match("%.mp3$") or m.name:lower():match("%.wav$")
       or m.name:lower():match("%.m4a$") then
      P:add_source(TMP .. "/" .. m.name, 2, 44100, audio_len or 4.0,
                   harness.sine_signal(0.4))
    end
  end
  harness.popen(P, "unzip -Z1", names)
end

local function run_import(P)
  P.file_dialog = ZIP
  harness.click(P, "Browse…")
  harness.click(P, "Import into REAPER!")
  local _, ok, err = harness.run(SCRIPT, P)
  if ok then harness.pump(P, 2) end
  return ok, err
end

return function(t)

  t.group("SGM_Suno ZIP Importer")

  t.test("imports stems into a closed, colour-coded folder", function()
    local P = harness.project()
    make_zip(P, {
      { name = "info.json",          data = INFO_JSON },
      { name = "instrumental.mp3" },
      { name = "vocals.mp3" },
      { name = "no_drums.mp3" },
    })

    local ok, err = run_import(P)
    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.eq(#P.tracks, 4, "folder + three stem tracks")
    t.ok(P.tracks[1].name:find("My Song", 1, true) ~= nil,
         "folder named after the song (got " .. tostring(P.tracks[1].name) .. ")")
    t.eq(P.tracks[1].folderdepth, 1, "first track opens the folder")
    t.eq(P:folder_balance(), 0, "folder depth is balanced (no dangling folder)")
    t.eq(P.undo_depth, 0, "undo block balanced")
    t.eq(P.tracks[2].items[1].pos, 0, "first stem at project start")
    t.approx(P.tracks[2].items[1].len, 4.0, 0.001, "item length from the source")
  end)

  t.test("stem order: instrumental first, then vocals", function()
    local P = harness.project()
    make_zip(P, {
      { name = "info.json", data = INFO_JSON },
      { name = "vocals.mp3" },
      { name = "instrumental.mp3" },
    })
    local ok = run_import(P)
    t.ok(ok, "script runs")
    t.ok(P.tracks[2].name:find("Instrumental", 1, true) ~= nil,
         "instrumental is the first child (got " .. tostring(P.tracks[2].name) .. ")")
    t.ok(P.tracks[3].name:find("Vocals", 1, true) ~= nil, "vocals second")
  end)

  t.test("lyrics become structural markers and Project Notes", function()
    local P = harness.project()
    make_zip(P, { { name = "info.json", data = INFO_JSON }, { name = "vocals.mp3" } })
    local ok = run_import(P)
    t.ok(ok, "script runs")
    t.eq(#P.markers, 2, "one marker per [Verse]/[Chorus] tag")
    if #P.markers == 2 then
      t.eq(P.markers[1].name, "Verse", "first marker is the Verse")
      t.eq(P.markers[2].name, "Chorus", "second marker is the Chorus")
      t.ok(P.markers[1].pos > 0 and P.markers[1].pos < 4.0, "marker inside the timeline")
    end
    t.ok(P.notes:find("hello there", 1, true) ~= nil, "lyrics written to Project Notes")
    t.ok(P.notes:find("pop, synthwave", 1, true) ~= nil, "tags written to Project Notes")
  end)

  t.test("temp folder is always cleaned up", function()
    local P = harness.project()
    make_zip(P, { { name = "info.json", data = INFO_JSON }, { name = "vocals.mp3" } })
    run_import(P)
    local cleaned = false
    for _, cmd in ipairs(P.removed) do
      if cmd:find(TMP, 1, true) then cleaned = true end
    end
    t.ok(cleaned, "rm -rf ran against the temp folder")
  end)

  t.test("rejects zip-slip members before extracting anything", function()
    local P = harness.project()
    harness.popen(P, "unzip -Z1", { "info.json", "../../evil.mp3" })
    P.zip_contents = {
      { name = "info.json", data = INFO_JSON },
      { name = "../../evil.mp3" },
    }
    local ok = run_import(P)
    t.ok(ok, "script exits cleanly (no crash)")
    t.eq(#P.tracks, 0, "no tracks created")
    t.ok(harness.console_contains(P, "Unsafe path"), "logs the rejected member")
    local extracted = false
    for _, cmd in ipairs(P.shell) do
      if cmd:find("unzip %-o") or cmd:find("Expand%-Archive") then extracted = true end
    end
    t.ok(not extracted, "extraction never ran")
  end)

  t.test("also rejects absolute paths and drive letters", function()
    for _, bad in ipairs({ "/etc/passwd.mp3", "C:\\Windows\\evil.mp3" }) do
      local P = harness.project()
      harness.popen(P, "unzip -Z1", { bad })
      local ok = run_import(P)
      t.ok(ok, "clean exit for " .. bad)
      t.eq(#P.tracks, 0, "no tracks for " .. bad)
      t.ok(harness.console_contains(P, "Unsafe path"), "rejected: " .. bad)
    end
  end)

  t.test("a ZIP filename with shell metacharacters is neutralised", function()
    local P = harness.project()
    make_zip(P, { { name = "info.json", data = INFO_JSON }, { name = "vocals.mp3" } })
    P.file_dialog = "/home/u/$(rm -rf ~);echo.zip"
    harness.click(P, "Browse…")
    harness.click(P, "Import into REAPER!")
    local ok = harness.run(SCRIPT, P)
    if ok then harness.pump(P, 2) end
    t.ok(ok, "script runs")
    for _, cmd in ipairs(P.shell) do
      -- Single-quoted regions are inert; strip them before looking for
      -- substitution / backticks / unquoted separators.
      local bare = cmd:gsub("'[^']*'", "''")
      t.ok(not bare:find("%$%("), "no live command substitution: " .. cmd)
      t.ok(not bare:find("`"), "no live backticks: " .. cmd)
    end
  end)

  t.test("info.json unicode escapes are decoded", function()
    local P = harness.project()
    make_zip(P, {
      { name = "info.json", data = '{"title":"Caf\\u00e9 \\u00dcber","prompt":""}' },
      { name = "vocals.mp3" },
    })
    local ok = run_import(P)
    t.ok(ok, "script runs")
    t.eq(P.tracks[1].name, "[Suno] Café Über", "UTF-8 decoded title")
  end)

  t.test("missing info.json falls back to the ZIP name", function()
    local P = harness.project()
    make_zip(P, { { name = "vocals.mp3" } })
    local ok = run_import(P)
    t.ok(ok, "script runs")
    t.eq(#P.tracks, 2, "folder + one stem")
    t.ok(P.tracks[1].name:find("Song One", 1, true) ~= nil,
         "title from the ZIP filename (got " .. tostring(P.tracks[1].name) .. ")")
  end)

  t.test("accepts .m4a and .flac, not just .mp3/.wav", function()
    local P = harness.project()
    P.sources = P.sources or {}
    harness.popen(P, "unzip -Z1", { "vocals.m4a", "instrumental.flac" })
    P.zip_contents = { { name = "vocals.m4a" }, { name = "instrumental.flac" } }
    P:add_source(TMP .. "/vocals.m4a", 2, 44100, 3.0, harness.sine_signal(0.3))
    P:add_source(TMP .. "/instrumental.flac", 2, 44100, 3.0, harness.sine_signal(0.3))
    local ok = run_import(P)
    t.ok(ok, "script runs")
    t.eq(#P.tracks, 3, "folder + both alternate-format stems")
  end)

  t.test("a ZIP with no audio reports an error and leaves no tracks", function()
    local P = harness.project()
    make_zip(P, { { name = "info.json", data = INFO_JSON }, { name = "cover.jpg" } })
    local ok = run_import(P)
    t.ok(ok, "script exits cleanly")
    t.eq(#P.tracks, 0, "no tracks")
    t.ok(harness.console_contains(P, "No audio files"), "explains the problem")
  end)

  t.test("missing ReaImGui shows a dependency message instead of crashing", function()
    local P = harness.project()
    P.no_imgui = true
    local _, ok, err = harness.run(SCRIPT, P)
    t.ok(ok, "script exits cleanly (got: " .. tostring(err) .. ")")
    t.ok(harness.dialogs_contain(P, "ReaImGui"), "names the missing dependency")
    t.eq(#P.tracks, 0, "nothing imported")
  end)
end
