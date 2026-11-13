--[[============================================================================
  tap.lua — minimal test harness (no external dependencies, Lua 5.4).

  Usage from a suite file:

      return function(t)
        t.test("does the thing", function()
          t.eq(actual, expected, "message")
        end)
      end
============================================================================]]--

local M = {}

local function new()
  local self = {
    passed = 0, failed = 0, errors = 0, failures = {}, current = "?",
  }

  function self.group(name) self.current = name end

  function self.ok(cond, msg)
    if cond then
      self.passed = self.passed + 1
      return true
    end
    self.failed = self.failed + 1
    self.failures[#self.failures + 1] =
      ("  FAIL [%s] %s"):format(self.current, msg or "assertion failed")
    return false
  end

  function self.eq(actual, expected, msg)
    local ok = actual == expected
    if not ok then
      self.failures[#self.failures + 1] = ("  FAIL [%s] %s\n         expected: %s\n         actual:   %s")
        :format(self.current, msg or "eq", tostring(expected), tostring(actual))
      self.failed = self.failed + 1
      return false
    end
    self.passed = self.passed + 1
    return true
  end

  function self.approx(actual, expected, tol, msg)
    local ok = type(actual) == "number" and math.abs(actual - expected) <= tol
    if not ok then
      self.failures[#self.failures + 1] = ("  FAIL [%s] %s\n         expected: %.4f ± %g\n         actual:   %s")
        :format(self.current, msg or "approx", expected, tol, tostring(actual))
      self.failed = self.failed + 1
      return false
    end
    self.passed = self.passed + 1
    return true
  end

  function self.ne(actual, unexpected, msg)
    return self.ok(actual ~= unexpected, msg or ("expected value to differ from " .. tostring(unexpected)))
  end

  function self.test(name, fn)
    local prev = self.current
    self.current = name
    local ok, err = pcall(fn)
    if not ok then
      self.errors = self.errors + 1
      self.failures[#self.failures + 1] = ("  ERROR [%s] %s"):format(name, tostring(err))
    end
    self.current = prev
  end

  function self.report(suite_name)
    for _, f in ipairs(self.failures) do
      io.stderr:write(f, "\n")
    end
    local status = (self.failed == 0 and self.errors == 0) and "ok" or "FAILED"
    io.write(("%-28s %s  (%d passed, %d failed, %d errors)\n")
      :format(suite_name or "suite", status, self.passed, self.failed, self.errors))
    return self.failed == 0 and self.errors == 0
  end

  return self
end

M.new = new
return M
