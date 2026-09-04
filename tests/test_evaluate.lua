local moonbug = require "src.moonbug"

local evaluate_expr = moonbug._internal.evaluate_expr

test("reads locals of the target frame", function()
    local function scenario()
        local x = 10
        local y = 41
        local ok, res, count = evaluate_expr(1, "x + y")
        return ok, res, count
    end

    local ok, res, count = scenario()
    expect.eq(true, ok)
    expect.eq(51, res[1])
    expect.eq(1, count)
end)

test("assignment writes back into a local", function()
    local function scenario()
        local value = 1
        local ok = evaluate_expr(1, "value = 41")
        return ok, value
    end

    local ok, value = scenario()
    expect.eq(true, ok)
    expect.eq(41, value)
end)

test("assignment writes back into an upvalue", function()
    local function outer()
        local upvalue = 68
        local function scenario()
            local snapshot = upvalue
            local ok, res, count = evaluate_expr(1, "upvalue = upvalue + 1")
            return ok, res, count, snapshot
        end
        local ok, res, count, snapshot = scenario()
        return ok, res, count, snapshot, upvalue
    end

    local ok, res, count, snapshot, upvalue = outer()
    expect.eq(true, ok)
    expect.eq(nil, res[1]) -- assignment statement: returns nil
    expect.eq(1, count)
    expect.eq(68, snapshot) -- value before eval
    expect.eq(69, upvalue) -- upvalue after eval
end)

test("varargs are visible", function()
    local function scenario(...)
        local ok, res, count = evaluate_expr(1, 'return select("#", ...)')
        return ok, res, count
    end

    local ok, res, count = scenario("a", "b", "c")
    expect.eq(true, ok)
    expect.eq(3, res[1])
    expect.eq(1, count)
end)

test("multiple return values are preserved", function()
    local function scenario()
        local ok, res, count = evaluate_expr(1, 'return string.find("hello world", "world")')
        return ok, res, count
    end

    local ok, res, count = scenario()
    expect.eq(true, ok)
    expect.eq(2, count)
    expect.eq(7, res[1])
    expect.eq(11, res[2])
end)

test("nil results rely on count, not #values", function()
    local function scenario()
        local ok, res, count = evaluate_expr(1, "return nil, 2")
        return ok, res, count
    end

    local ok, res, count = scenario()
    expect.eq(true, ok)
    expect.eq(2, count)
    expect.eq(nil, res[1])
    expect.eq(2, res[2])
end)

test("runtime and compile errors surface, not throw", function()
    local function scenario(src)
        local ok, res, count = evaluate_expr(1, src)
        return ok, res, count
    end

    local ok, msg = scenario "error('boom')"
    expect.eq(false, ok)
    expect.not_nil(msg)

    local ok2, msg2 = scenario "1 +"
    expect.eq(false, ok2)
    expect.not_nil(msg2)
end)

test("runaway evaluation is aborted after timeout", function()
    local function scenario()
        local started = os.clock()
        local ok, res, count = evaluate_expr(1, "while true do end", 0.05)
        return ok, res, count, os.clock() - started
    end

    -- hook from before running the scenario
    local hook = debug.gethook()

    local ok, msg, _, elapsed = scenario()
    expect.eq(false, ok)
    expect.not_nil(tostring(msg):match "timed out")
    expect.eq(true, elapsed < 2) -- aborted, didn't hang
    expect.eq(hook, debug.gethook()) -- hook gets cleared even after abort
end)

test("finite work under the timeout is not killed", function()
    local function scenario()
        local ok, res, count = evaluate_expr(1, "local t = 0 for i = 1, 200000 do t = t + i end return t", 5)
        return ok, res, count
    end

    -- hook from before running the scenario
    local hook = debug.gethook()

    local ok, _, count = scenario()
    expect.eq(true, ok)
    expect.eq(1, count)
    expect.eq(hook, debug.gethook()) -- hook gets cleared on success
end)

test("repl context can mutate a local", function()
    local function scenario()
        local value = 1
        local ok = evaluate_expr(1, "value = 41", nil, "repl")
        return ok, value
    end

    local ok, value = scenario()
    expect.eq(true, ok)
    expect.eq(41, value)
end)

test("missing context still behaves like repl", function()
    local function scenario()
        local value = 1
        local ok = evaluate_expr(1, "value = 7")
        return ok, value
    end

    local ok, value = scenario()
    expect.eq(true, ok)
    expect.eq(7, value)
end)

test("read-only contexts reject assignments without mutating", function()
    for _, context in ipairs { "watch", "hover", "clipboard", "variables" } do
        local function scenario()
            local value = 1
            local ok, msg = evaluate_expr(1, "value = 41", nil, context)
            return ok, msg, value
        end

        local ok, msg, value = scenario()
        expect.eq(false, ok, context .. " assignment should be rejected")
        expect.not_nil(msg)
        expect.eq(1, value, context .. " must not write back")
    end
end)

test("read-only contexts reject local declarations", function()
    for _, context in ipairs { "hover", "watch" } do
        local function scenario()
            local ok, msg = evaluate_expr(1, "local y = 5", nil, context)
            return ok, msg
        end

        expect.eq(false, scenario(), context .. " local decl should be rejected")
    end
end)

test("watch context reads locals as expressions", function()
    local function scenario()
        local value = 41
        local ok, res, count = evaluate_expr(1, "value + 1", nil, "watch")
        return ok, res, count
    end

    local ok, res, count = scenario()
    expect.eq(true, ok)
    expect.eq(42, res[1])
    expect.eq(1, count)
end)

test("watch context preserves multiple return values", function()
    local function scenario()
        local ok, res, count = evaluate_expr(1, 'string.find("hello world", "world")', nil, "watch")
        return ok, res, count
    end

    local ok, res, count = scenario()
    expect.eq(true, ok)
    expect.eq(2, count)
    expect.eq(7, res[1])
    expect.eq(11, res[2])
end)

test("watch returns a call value; repl treats the call as a statement", function()
    local function run(context)
        local ok, res, count = evaluate_expr(1, "os.clock()", nil, context)
        return ok, res, count
    end

    local ok, res, _ = run "watch"
    expect.eq(true, ok)
    expect.eq("number", type(res[1]))

    local ok2, res2 = run "repl"
    expect.eq(true, ok2)
    expect.eq(nil, res2[1]) -- raw-compiled as a statement
end)

test("read-only contexts leave upvalues untouched", function()
    local function outer()
        local counter = 0
        local function scenario()
            local seen = counter
            local ok = evaluate_expr(1, "counter = counter + 1", nil, "watch")
            return ok, seen, counter
        end

        local ok, seen, new_counter = scenario()
        return ok, seen, new_counter
    end

    local ok, seen, counter = outer()
    expect.eq(false, ok)
    expect.eq(0, seen)
    expect.eq(0, counter)
end)
