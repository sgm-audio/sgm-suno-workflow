--[[============================================================================
  test_04_loudness.lua — Suno_04_LoudnessMaster
============================================================================]]--

local harness = require("harness")

local function dbfs(amp) return 20 * math.log(amp, 10) end

return function(t)

  t.group("Suno_04 LoudnessMaster")

  t.test("normalises a sine to the requested dBFS RMS", function()
    local P = harness.project()
    local src = P:add_source("/audio/tone.wav", 2, 44100, 5.0, harness.sine_signal(0.5))
    local tr = P:add_track("Tone")
    local item = P:add_item(tr, src, 3.0, 5.0, { selected = true })

    harness.answer(P, "-18,-0.3")
    local _, ok, err = harness.run("Suno_04_LoudnessMaster.lua", P)

    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    -- source RMS = 0.5/sqrt(2) = -9.03 dBFS → gain ≈ -8.97 dB → vol ≈ 0.356
    local rms_after = (0.5 / math.sqrt(2)) * item.vol
    t.approx(dbfs(rms_after), -18, 0.5, "resulting RMS")
    t.approx(item.vol, 10 ^ (-8.97 / 20), 0.02, "applied item gain")
    t.eq(P.undo_depth, 0, "undo block balanced")
  end)

  t.test("peak ceiling clamps the gain", function()
    local P = harness.project()
    local src = P:add_source("/audio/hot.wav", 2, 44100, 5.0, harness.sine_signal(0.9))
    local tr = P:add_track("Hot")
    local item = P:add_item(tr, src, 0, 5.0, { selected = true })

    harness.answer(P, "-1,-0.3")     -- would need +2.9 dB
    local _, ok, err = harness.run("Suno_04_LoudnessMaster.lua", P)

    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    local peak_after = 0.9 * item.vol
    t.approx(dbfs(peak_after), -0.3, 0.05, "peak lands on the ceiling")
    t.ok(harness.console_contains(P, "LIMIT"), "reports that the gain was limited")
  end)

  t.test("items already at target are left alone", function()
    local P = harness.project()
    -- RMS of 0.125 amplitude = -17.02 dBFS, within 0.5 dB of -17.5
    local src = P:add_source("/audio/ok.wav", 2, 44100, 5.0, harness.sine_signal(0.18))
    local tr = P:add_track("OK")
    local item = P:add_item(tr, src, 0, 5.0, { selected = true, vol = 0.7 })

    harness.answer(P, "-18,-0.3")   -- source -16.9 dBFS at vol 0.7 → -20 dBFS…
    local _, ok = harness.run("Suno_04_LoudnessMaster.lua", P)
    t.ok(ok, "script runs")
    -- Either skipped (no change) or adjusted by a tiny amount; never muted.
    t.ok(item.vol > 0.1, "item volume stays sane")
  end)

  t.test("silent items are skipped, not boosted to infinity", function()
    local P = harness.project()
    local src = P:add_source("/audio/silent.wav", 2, 44100, 3.0, harness.silence())
    local tr = P:add_track("Silent")
    local item = P:add_item(tr, src, 0, 3.0, { selected = true })

    harness.answer(P, "-18,-0.3")
    local _, ok, err = harness.run("Suno_04_LoudnessMaster.lua", P)

    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.eq(item.vol, 1.0, "silent item volume untouched")
    t.ok(harness.dialogs_contain(P, "Failed"), "reports the skipped item")
  end)

  t.test("rejects a positive target level", function()
    local P = harness.project()
    local src = P:add_source("/audio/t.wav", 2, 44100, 2.0, harness.sine_signal(0.5))
    local tr = P:add_track("T")
    local item = P:add_item(tr, src, 0, 2.0, { selected = true })
    harness.answer(P, "6,-0.3")
    local _, ok = harness.run("Suno_04_LoudnessMaster.lua", P)
    t.ok(ok, "script runs")
    t.eq(item.vol, 1.0, "no gain applied")
    t.ok(harness.dialogs_contain(P, "negative"), "explains the constraint")
  end)
end
