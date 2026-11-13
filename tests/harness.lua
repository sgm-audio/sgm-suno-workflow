--[[============================================================================
  harness.lua — glue between the suites and the mock API.
============================================================================]]--

local mock = require("mock_reaper")

local M = {}

M.mock = mock

-- Repo root: suites are executed from the repository root.
M.ROOT = "."

function M.suite_start(_name) end

--- Create an empty mock project.
function M.project() return mock.new_project() end

--- Load and execute a script inside its own sandbox environment.
-- Returns: env, ok, err
function M.run(script_rel_path, P)
  local env = mock.new_env(P)
  local chunk, load_err = loadfile(M.ROOT .. "/" .. script_rel_path, "t", env)
  if not chunk then
    return env, false, "load error: " .. tostring(load_err)
  end
  local ok, err = pcall(chunk)
  return env, ok, err
end

--- Only load (syntax check) without executing.
function M.compile(script_rel_path)
  local chunk, err = loadfile(M.ROOT .. "/" .. script_rel_path, "t", {})
  return chunk ~= nil, err
end

--- Re-run deferred callbacks (the ImGui loop) n times.
function M.pump(P, n)
  for _ = 1, (n or 1) do
    local fns = P.deferred
    P.deferred = {}
    if #fns == 0 then return end
    for _, fn in ipairs(fns) do
      local ok, err = pcall(fn)
      if not ok then error("deferred callback failed: " .. tostring(err), 0) end
    end
  end
end

--- Queue a GetUserInputs answer. Pass false to simulate the user cancelling.
function M.answer(P, csv) table.insert(P.prompts, csv) end

--- Queue an ImGui button click by label.
function M.click(P, label) table.insert(P.imgui.buttons, label) end

--- Register an in-memory file.
function M.file(P, path, contents) P.fs[path] = contents end

--- Register an in-memory directory.
function M.dir(P, path) P.dirs[path] = true end

--- Register canned output for io.popen() commands containing `needle`.
function M.popen(P, needle, lines) P.popen[needle] = lines end

--- Last dialog message (for asserting on user-facing errors).
function M.last_dialog(P)
  local d = P.dialogs[#P.dialogs]
  return d and d.msg or ""
end

function M.dialogs_contain(P, needle)
  for _, d in ipairs(P.dialogs) do
    if d.msg:find(needle, 1, true) then return true end
  end
  return false
end

function M.console_contains(P, needle)
  return P:console_text():find(needle, 1, true) ~= nil
end

-- ─── signal generators ─────────────────────────────────────────────────────

-- Metronome-like click track at `bpm`; `amp` peak amplitude, `decay` length.
function M.click_signal(bpm, amp, decay)
  local period = 60 / bpm
  amp = amp or 0.8
  decay = decay or 0.01
  return function(t)
    if t < 0 then return { 0, 0 } end
    local phase = t % period
    local v = 0
    if phase < decay then
      -- short exponentially decaying burst
      v = amp * math.exp(-phase / (decay / 4))
    end
    return { v, v }
  end
end

-- Section-based signal: list of { to_time, amp } (ascending `to_time`).
function M.section_signal(sections)
  return function(t)
    if t < 0 then return { 0, 0 } end
    local amp = sections[#sections].amp
    for _, s in ipairs(sections) do
      if t < s.to_time then amp = s.amp break end
    end
    -- A steady tone makes the RMS well-defined for energy tests.
    local v = amp * math.sin(2 * math.pi * 220 * t)
    return { v, v }
  end
end

-- Constant-amplitude sine: RMS = amp / sqrt(2).
function M.sine_signal(amp, freq)
  freq = freq or 440
  return function(t)
    local v = amp * math.sin(2 * math.pi * freq * t)
    return { v, v }
  end
end

-- Silent signal.
function M.silence()
  return function() return { 0, 0 } end
end

return M
