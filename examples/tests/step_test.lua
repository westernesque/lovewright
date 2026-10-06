--- Tests for lovewright.step (test.step) itself
-- No game needed: these check what a step returns, how it rethrows, and
-- which step a failure is pinned on.

package.path = "./?.lua;./?/init.lua;" .. package.path

local lovewright = require("lovewright")
local Step = require("lovewright.step")
local describe, it, expect = lovewright.describe, lovewright.it, lovewright.expect
local step = lovewright.step

describe("Steps", function()
  it("returns every value the step body returns", function()
    local a, b, c = step("compute", function()
      return 1, nil, "three"
    end)
    expect(a):toBe(1)
    expect(b):toBeNil()
    expect(c):toBe("three")
  end)

  it("is also reachable as test.step and it.step", function()
    expect(lovewright.test.step):toBe(lovewright.step)
    expect(lovewright.it.step):toBe(lovewright.step)
    expect(lovewright.test.step("alias", function() return "ok" end)):toBe("ok")
  end)

  it("rethrows the body's error unchanged", function()
    local thrown = { custom = true }
    local ok, err = pcall(step, "throws a table", function()
      error(thrown)
    end)
    expect(ok):toBe(false)
    expect(err):toBe(thrown)

    ok, err = pcall(step, "throws a string", function()
      error("plain message", 0)
    end)
    expect(err):toBe("plain message")
  end)

  it("pins a failure on the innermost step it came from", function()
    local ok, err = pcall(step, "outer", function()
      step("first inner", function() end)
      step("second inner", function()
        step("deepest", function()
          error("boom", 0)
        end)
      end)
    end)
    expect(ok):toBe(false)
    expect(Step.failed_in(err)):toBe("outer > second inner > deepest")
  end)

  it("pins an error raised between nested steps on the step around it", function()
    local ok, err = pcall(step, "outer", function()
      step("inner", function() end)
      error("after the inner step", 0)
    end)
    expect(Step.failed_in(err)):toBe("outer")
  end)

  it("forgets a step failure the test caught", function()
    pcall(step, "caught", function() error("ignored", 0) end)
    step("carries on", function() end)
    expect(Step.failed_in("ignored")):toBeNil()
  end)

  it("records the step outline of the test", function()
    step("one", function()
      step("one.a", function() end)
    end)
    step("two", function() end)
    local tree = Step.tree()
    expect(#tree):toBe(2)
    expect(tree[1].name):toBe("one")
    expect(tree[1].status):toBe("passed")
    expect(tree[1].children[1].name):toBe("one.a")
    expect(tree[2].name):toBe("two")
  end)

  it("rejects a step without a body", function()
    local ok, err = pcall(step, "no body")
    expect(ok):toBe(false)
    expect(tostring(err)):toContain("fn must be a function")
  end)
end)
