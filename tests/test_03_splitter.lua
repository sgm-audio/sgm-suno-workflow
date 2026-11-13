--[[============================================================================
  test_03_splitter.lua — Suno_03_DynamicSplitter
============================================================================]]--

local harness = require("harness")

-- Quiet → loud → quiet → loud, so the detector sees rising energy at 9 s and 27 s.
local function section_item(P, pos, quiet, loud)
  local q, l = quiet or 0.05, loud or 0.9
  local src = P:add_source("/audio/sections.wav", 2, 44100, 36.0,
    harness.section_signal({
      { to_time = 9,  amp = q },
      { to_time = 18, amp = l },
      { to_time = 27, amp = q },
      { to_time = 36, amp = l },
    }))
  local tr = P:add_track("Sections")
  return P:add_item(tr, src, pos, 36.0, { selected = true })
end

return function(t)

  t.group("Suno_03 DynamicSplitter")

  t.test("splits at the energy rise, at the right project time", function()
    local P = harness.project()
    section_item(P, 0, 0.05, 0.9)
    harness.answer(P, "0.40,8,12")

    local _, ok, err = harness.run("Suno_03_DynamicSplitter.lua", P)
    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.ok(not P.oob, "peak buffer is not over-read")

    local tr = P.tracks[1]
    t.ok(#tr.items >= 2, "item was split (got " .. #tr.items .. " items)")
    if #tr.items >= 2 then
      t.approx(tr.items[2].pos, 9.0, 1.0, "first split lands on the 9 s transition")
    end
  end)

  t.test("items stay contiguous and keep the original length", function()
    local P = harness.project()
    section_item(P, 4.0)   -- item starts at 4 s: catches take-relative start times
    harness.answer(P, "0.40,8,12")

    local _, ok, err = harness.run("Suno_03_DynamicSplitter.lua", P)
    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")

    local tr = P.tracks[1]
    table.sort(tr.items, function(a, b) return a.pos < b.pos end)
    local total = 0
    for i, it in ipairs(tr.items) do
      total = total + it.len
      if i > 1 then
        t.approx(it.pos, tr.items[i - 1].pos + tr.items[i - 1].len, 0.002,
                 "no gap/overlap between item " .. i .. " and " .. (i - 1))
      end
    end
    t.approx(total, 36.0, 0.002, "total duration preserved")
    t.approx(tr.items[1].pos, 4.0, 0.001, "first item keeps its position")
  end)

  t.test("sections are named Sec 01..N in timeline order", function()
    local P = harness.project()
    section_item(P, 0)
    harness.answer(P, "0.40,8,12")
    local _, ok = harness.run("Suno_03_DynamicSplitter.lua", P)
    t.ok(ok, "script runs")

    local tr = P.tracks[1]
    table.sort(tr.items, function(a, b) return a.pos < b.pos end)
    t.eq(#tr.items, 3, "two energy rises → three sections")
    t.ok(tr.items[1].take.name:find("Sec 01", 1, true) ~= nil,
         "first section named Sec 01 (got " .. tostring(tr.items[1].take.name) .. ")")
    t.ok(tr.items[2].take.name:find("Sec 02", 1, true) ~= nil, "second section named Sec 02")
    t.ok(tr.items[3].take.name:find("Sec 03", 1, true) ~= nil, "third section named Sec 03")
  end)

  t.test("higher sensitivity splits less (strict), lower splits more (loose)", function()
    local function run(sens)
      local P = harness.project()
      -- Several rises of different strengths.
      local src = P:add_source("/audio/mixed.wav", 2, 44100, 40.0,
        harness.section_signal({
          { to_time = 9,  amp = 0.05 },
          { to_time = 18, amp = 0.60 },
          { to_time = 27, amp = 0.05 },
          { to_time = 36, amp = 0.75 },
          { to_time = 40, amp = 0.05 },
        }))
      local tr = P:add_track("Mixed")
      P:add_item(tr, src, 0, 40.0, { selected = true })
      harness.answer(P, sens .. ",8,12")
      local _, ok, err = harness.run("Suno_03_DynamicSplitter.lua", P)
      t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
      return #tr.items - 1
    end
    local loose  = run("0.10")
    local strict = run("1.00")
    t.ok(loose >= strict,
         ("loose splits (%d) >= strict splits (%d)"):format(loose, strict))
    t.ok(loose > 0, "loose setting still finds sections")
  end)

  t.test("very short item is handled without crashing", function()
    local P = harness.project()
    local src = P:add_source("/audio/tiny.wav", 2, 44100, 0.05,
                             function() return { 0.5, 0.5 } end)
    local tr = P:add_track("Tiny")
    P:add_item(tr, src, 0, 0.05, { selected = true })
    harness.answer(P, "0.40,8,12")

    local _, ok, err = harness.run("Suno_03_DynamicSplitter.lua", P)
    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.eq(#P.tracks[1].items, 1, "no split on a 50 ms item")
    t.eq(P.undo_depth, 0, "undo block balanced")
  end)

  t.test("empty parameter fields do not shift the other settings", function()
    local P = harness.project()
    section_item(P, 0)
    harness.answer(P, ",8,12")   -- blank sensitivity → default 0.40
    local _, ok, err = harness.run("Suno_03_DynamicSplitter.lua", P)
    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.ok(#P.tracks[1].items >= 2, "still splits with the default sensitivity")
  end)
end
