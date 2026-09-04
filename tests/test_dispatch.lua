local moonbug = require "src.moonbug"
local dap = require "tests.utils_dap"

local p = moonbug._internal

before_each(function()
    p.reset()
end)

---@param peer moonbug.Socket
---@param conn moonbug.Socket
---@param req  table
local function roundtrip(peer, conn, req)
    p.session.client = conn
    p.dispatch(req)
    return dap.read_msg(peer)
end

test("initialize responds with capabilities and announces initialized", function()
    dap.with_socket_pair(function(peer, conn)
        local req = {
            type = "request",
            command = "initialize",
            seq = 1,
            arguments = { adapterID = "tests", supportsVariablePaging = true },
        }

        local resp = roundtrip(peer, conn, req)
        dap.expect_response(resp, req, true)
        expect.eq(true, resp.body.supportsConditionalBreakpoints)
        expect.eq(true, resp.body.supportsEvaluateForHovers)
        expect.eq(true, resp.body.supportsExceptionFilterOptions)
        expect.eq(true, p.session.client_args.supportsVariablePaging)

        local ev = dap.read_msg(peer)
        expect.eq("event", ev.type)
        expect.eq("initialized", ev.event)
    end)
end)

test("setExceptionBreakpoints toggles filters in both directions", function()
    dap.with_socket_pair(function(peer, conn)
        local req = {
            type = "request",
            command = "setExceptionBreakpoints",
            seq = 1,
            arguments = { filters = { "pcall" } },
        }

        local resp = roundtrip(peer, conn, req)
        dap.expect_response(resp, req, true)
        expect.eq(false, p.session.filters.error)
        expect.eq(true, p.session.filters.pcall)
        expect.eq(false, p.session.filters.uncaught)

        local req2 = {
            type = "request",
            command = "setExceptionBreakpoints",
            seq = 2,
            arguments = { filters = { "error", "uncaught" } },
        }

        roundtrip(peer, conn, req2)
        expect.eq(true, p.session.filters.error)
        expect.eq(false, p.session.filters.pcall)
        expect.eq(true, p.session.filters.uncaught)
    end)
end)

test("setBreakpoints resolves paths and stores condition fields", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.project_root_dir = "/proj"

        local req = {
            type = "request",
            command = "setBreakpoints",
            seq = 1,
            arguments = {
                source = { path = "/proj/examples/01-wait.lua" },
                breakpoints = {
                    { line = 3, condition = "x == 5" },
                    { line = 12, hitCondition = "> 2" },
                },
            },
        }

        local resp = roundtrip(peer, conn, req)
        dap.expect_response(resp, req, true)
        expect.eq(true, resp.body.breakpoints[1].verified)
        expect.eq(true, resp.body.breakpoints[2].verified)

        local bps = p.session.breakpoints["/proj/examples/01-wait.lua"]
        expect.eq("x == 5", bps[3].condition)
        expect.eq("> 2", bps[12].hit_condition)
        expect.eq(0, bps[12].hit_count)
    end)
end)

test("setBreakpoints flags unusable entries and replaces per-file state", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.project_root_dir = "/proj"

        roundtrip(peer, conn, {
            type = "request",
            command = "setBreakpoints",
            seq = 1,
            arguments = { source = { path = "main.lua" }, breakpoints = { { line = 3 } } },
        })

        local req = {
            type = "request",
            command = "setBreakpoints",
            seq = 2,
            arguments = {
                source = { path = "main.lua" },
                breakpoints = { { line = 5 }, {} },
            },
        }

        local resp = roundtrip(peer, conn, req)
        expect.eq(true, resp.body.breakpoints[1].verified)
        expect.eq(false, resp.body.breakpoints[2].verified)

        local bps = p.session.breakpoints["/proj/main.lua"]
        expect.eq(nil, bps[3])
        expect.not_nil(bps[5])
    end)
end)

test("continue while paused clears state and emits continued", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.ready = true
        p.session.paused = true
        p.session.frames = { [1] = 4 }
        p.session.variables.refs = { [7] = { kind = "table", data = { tbl = {} } } }

        local req = { type = "request", command = "continue", seq = 1 }
        local resp = roundtrip(peer, conn, req)
        dap.expect_response(resp, req, true)
        expect.eq(true, resp.body.allThreadsContinued)
        expect.eq(false, p.session.paused)
        expect.eq(nil, p.session.step)
        expect.eq(0, #p.session.frames)
        expect.eq(0, #p.session.variables.refs)

        local ev = dap.read_msg(peer)
        expect.eq("event", ev.type)
        expect.eq("continued", ev.event)
        expect.eq(1, ev.body.threadId)
    end)
end)

test("continue while running is rejected with notStopped and leaves state alone", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.ready = true
        p.session.paused = false
        p.session.step = "over"

        local req = { type = "request", command = "continue", seq = 1 }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, false)
        expect.eq("notStopped", resp.message)
        expect.eq(false, p.session.paused)
        expect.eq("over", p.session.step)
    end)
end)

test("next, stepIn and stepOut setup their step and resume", function()
    for _, tc in ipairs { { "next", "over" }, { "stepIn", "in" }, { "stepOut", "out" } } do
        p.reset()

        dap.with_socket_pair(function(peer, conn)
            p.session.ready = true
            p.session.paused = true
            p.session.step = "pause"

            local req = { type = "request", command = tc[1], seq = 1 }
            local resp = roundtrip(peer, conn, req)

            dap.expect_response(resp, req, true)
            expect.eq(false, p.session.paused)
            expect.eq(tc[2], p.session.step)
        end)
    end
end)

test("stepping while running is rejected with notStopped", function()
    for _, cmd in ipairs { "next", "stepIn", "stepOut", "continue" } do
        p.reset()

        dap.with_socket_pair(function(peer, conn)
            p.session.ready = true
            p.session.paused = false

            local req = { type = "request", command = cmd, seq = 1 }
            local resp = roundtrip(peer, conn, req)

            dap.expect_response(resp, req, false)
            expect.eq("notStopped", resp.message)
        end)
    end
end)

test("pause setups a pause without requiring a stop first", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.ready = true
        p.session.paused = false
        local req = { type = "request", command = "pause", seq = 1 }
        local resp = roundtrip(peer, conn, req)
        dap.expect_response(resp, req, true)
        expect.eq("pause", p.session.step)
        expect.eq(false, p.session.paused)
    end)
end)
