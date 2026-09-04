local moonbug = require "src.moonbug"

local p = moonbug._internal

before_each(function()
    p.reset()
end)

after_each(function()
    p.remove_debug_hook()
end)

test("stack depth stays accurate across caught errors and tail calls", function()
    p.session.ready = true
    p.setup_debug_hook()

    local function inner()
        error "boom"
    end

    local function outer()
        pcall(inner)
    end

    local function g()
        return 1
    end

    local function f()
        return g()
    end

    local function t()
        f()
        f()
        f()
    end

    for _ = 1, 50 do
        outer()
        t()
    end

    expect.eq(0, p.get_stack_level(), "stack_level must not drift")
end)
