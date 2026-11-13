--[[============================================================================
  run_tests.lua — runs every suite against the mock REAPER API.

      lua5.4 tests/run_tests.lua            (from the repository root)

  Exit code 0 = all suites passed.
============================================================================]]--

-- Make `require "tests.mock_reaper"` work regardless of how we were invoked.
local here = (arg and arg[0] or "tests/run_tests.lua"):match("^(.*)[/\\][^/\\]+$") or "."
package.path = table.concat({
  "./?.lua",
  "./tests/?.lua",
  here .. "/?.lua",
  here .. "/../?.lua",
  package.path,
}, ";")

local tap = require("tap")
local harness = require("harness")

local SUITES = {
  "test_a_static",
  "test_01_metadata",
  "test_02_tempo",
  "test_03_splitter",
  "test_04_loudness",
  "test_05_stems",
  "test_zip_importer",
}

local all_ok = true
local total_passed, total_failed, total_errors = 0, 0, 0

for _, name in ipairs(SUITES) do
  local suite = require(name)
  local t = tap.new()
  harness.suite_start(name)
  local ok, err = pcall(function() suite(t) end)
  if not ok then
    t.errors = t.errors + 1
    t.failures[#t.failures + 1] = "  ERROR loading suite: " .. tostring(err)
  end
  local suite_ok = t.report(name)
  all_ok = all_ok and suite_ok
  total_passed = total_passed + t.passed
  total_failed = total_failed + t.failed
  total_errors = total_errors + t.errors
end

io.write(("\n%d passed, %d failed, %d errors\n"):format(total_passed, total_failed, total_errors))
if _G.EMBEDDED then return all_ok end
os.exit(all_ok and 0 or 1)
