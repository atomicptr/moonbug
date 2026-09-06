local moonbug = require "src.moonbug"
local dap = require "tests.utils_dap"

local p = moonbug._internal

---@param file string
---@param line integer
---@param bp? moonbug.Breakpoint
local function add_bp(file, line, bp)
    local key = p.path_resolve(file, p.session.project_root_dir)
    p.session.breakpoints[key] = p.session.breakpoints[key] or {}
    p.session.breakpoints[key][line] = bp or { hit_count = 0 }
end

before_each(function()
    p.reset()
    p.session.project_root_dir = "/proj"
end)

test("condition gates hit counting even when a hit_condition is set", function()
    local file = "@spec/fake.lua"

    add_bp(file, 12, { condition = "false", hit_condition = ">= 2", hit_count = 0 })
    expect.eq(false, p.hit_breakpoint(file, 12))
    expect.eq(false, p.hit_breakpoint(file, 12))
    local bps = p.session.breakpoints[p.path_resolve(file, p.session.project_root_dir)]
    expect.eq(0, bps[12].hit_count, "unmet condition must not count")

    bps[12] = { condition = "true", hit_condition = ">= 2", hit_count = 0 }
    expect.eq(false, p.hit_breakpoint(file, 12))
    expect.eq(true, p.hit_breakpoint(file, 12))
    expect.eq(2, bps[12].hit_count)
end)

test("bare number stops on the exact hit count", function()
    for i = 1, 10 do
        expect.eq(i == 5, p.hit_condition_met("5", i), "hit " .. i)
    end
end)

test("= and == behave like a bare number", function()
    expect.eq(true, p.hit_condition_met("= 5", 5))
    expect.eq(false, p.hit_condition_met("= 5", 4))
    expect.eq(true, p.hit_condition_met("==5", 5))
    expect.eq(false, p.hit_condition_met("==5", 6))
end)

test("comparison operators", function()
    expect.eq(false, p.hit_condition_met("> 5", 5))
    expect.eq(true, p.hit_condition_met("> 5", 6))
    expect.eq(false, p.hit_condition_met(">= 5", 4))
    expect.eq(true, p.hit_condition_met(">= 5", 5))
    expect.eq(true, p.hit_condition_met("< 5", 4))
    expect.eq(false, p.hit_condition_met("< 5", 5))
    expect.eq(true, p.hit_condition_met("<= 5", 5))
    expect.eq(false, p.hit_condition_met("<= 5", 6))
end)

test("~= and != match anything except the given count", function()
    expect.eq(true, p.hit_condition_met("~= 5", 4))
    expect.eq(false, p.hit_condition_met("~= 5", 5))
    expect.eq(true, p.hit_condition_met("!= 5", 6))
    expect.eq(false, p.hit_condition_met("!= 5", 5))
end)

test("% matches every Nth hit", function()
    for i = 1, 12 do
        expect.eq(i % 3 == 0, p.hit_condition_met("% 3", i), "hit " .. i)
    end
end)

test("% 0 never matches instead of raising", function()
    expect.eq(false, p.hit_condition_met("% 0", 1))
    expect.eq(false, p.hit_condition_met("% 0", 100))
end)

test("surrounding whitespace is ignored", function()
    expect.eq(true, p.hit_condition_met("  >=  5  ", 5))
    expect.eq(true, p.hit_condition_met("\t>= 5", 6))
end)

test("malformed hit conditions are rejected as not met", function()
    for _, bad in ipairs { "abc", "> = 5", "-5", "5.5", "5+3", ">= x", "" } do
        expect.eq(false, p.hit_condition_met(bad, 1), string.format("%q", bad))
    end
end)

test("hit_breakpoint ignores breakpoints on other lines", function()
    add_bp("@main.lua", 5)
    expect.eq(false, p.hit_breakpoint("@main.lua", 6))
    expect.eq(true, p.hit_breakpoint("@main.lua", 5))
end)

test("hit_breakpoint matches a @chunk source against an absolute-path breakpoint", function()
    add_bp("/proj/main.lua", 7)
    expect.eq(true, p.hit_breakpoint("@main.lua", 7))
end)

test("breakpoints on different lines count independently", function()
    add_bp("main.lua", 2)
    add_bp("main.lua", 9)
    p.hit_breakpoint("main.lua", 2)
    p.hit_breakpoint("main.lua", 9)
    p.hit_breakpoint("main.lua", 2)

    local bps = p.session.breakpoints["/proj/main.lua"]
    expect.eq(2, bps[2].hit_count)
    expect.eq(1, bps[9].hit_count)
end)

test("hit_condition '> N' only hits after the count passes N", function()
    add_bp("main.lua", 4, { hit_condition = "> 2", hit_count = 0 })
    expect.eq(false, p.hit_breakpoint("main.lua", 4))
    expect.eq(false, p.hit_breakpoint("main.lua", 4))
    expect.eq(true, p.hit_breakpoint("main.lua", 4))
    expect.eq(3, p.session.breakpoints["/proj/main.lua"][4].hit_count)
end)

test("hit_condition with an exact count hits on only that visit", function()
    add_bp("main.lua", 4, { hit_condition = "3", hit_count = 0 })
    expect.eq(false, p.hit_breakpoint("main.lua", 4))
    expect.eq(false, p.hit_breakpoint("main.lua", 4))
    expect.eq(true, p.hit_breakpoint("main.lua", 4))
    expect.eq(false, p.hit_breakpoint("main.lua", 4))
end)

test("log points interpolate expressions from the breakpoint frame", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.ready = true
        p.session.client = conn

        local file = "@spec/log.lua"
        add_bp(file, 12, { log_message = "secret is {secret}", hit_count = 0 })

        local secret = 42
        expect.eq(false, p.hit_breakpoint(file, 12), "log points must not stop")

        local ev = dap.read_msg(peer)
        expect.eq("event", ev.type)
        expect.eq("output", ev.event)
        expect.not_nil(ev.body.output:find("secret is 42", 1, true))
    end)
end)
