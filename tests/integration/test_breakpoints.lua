local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/breakpoints.lua"
local conditional_line = dap.find_marker(program, "conditional")
local hit_line = dap.find_marker(program, "hit")
local logpoint_line = dap.find_marker(program, "logpoint")
local repeated_line = dap.find_marker(program, "repeated")

---@param session moonbug.test.Session
---@param expected string
local function expect_console_output(session, expected)
    local event = session:wait_for_event("output", function(body)
        return body.category == "console"
    end)

    expect.eq(expected, event.body.output)
end

---@param session moonbug.test.Session
---@param stop moonbug.test.Stop
---@param expected string
local function expect_iteration(session, stop, expected)
    local response = dap.assert_success(session:request("evaluate", {
        frameId = stop.frame_id,
        expression = "i",
        context = "watch",
    }))

    expect.eq(expected, response.body.result)
end

test("handles conditions, hit counts, and logpoints", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                {
                    line = conditional_line,
                    condition = "i == 2",
                },
                {
                    line = hit_line,
                    hitCondition = "3",
                },
                {
                    line = logpoint_line,
                    logMessage = "LOG i={i}",
                },
            },
        }

        local conditional = session:wait_for_stop "breakpoint"
        expect.eq(conditional_line, conditional.frames[1].line)
        expect_iteration(session, conditional, "2")

        expect_console_output(session, "LOG i=1\n")

        dap.assert_success(session:request("continue", {
            threadId = conditional.thread_id,
        }))

        session:wait_for_event "continued"

        local hit = session:wait_for_stop "breakpoint"
        expect.eq(hit_line, hit.frames[1].line)
        expect_iteration(session, hit, "3")

        expect_console_output(session, "LOG i=2\n")

        dap.assert_success(session:request("continue", {
            threadId = hit.thread_id,
        }))

        session:wait_for_event "continued"

        expect_console_output(session, "LOG i=3\n")
        expect_console_output(session, "LOG i=4\n")
    end)
end)

test("replaces breakpoints and rejects entries without a line", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = conditional_line },
            },
        }

        local replacement = dap.assert_success(session:request("setBreakpoints", {
            source = { path = program },
            breakpoints = {
                {},
                { line = hit_line },
            },
        }))

        expect.is_false(replacement.body.breakpoints[1].verified)
        expect.is_true(replacement.body.breakpoints[2].verified)

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(hit_line, stop.frames[1].line)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)

test("converts zero-based client lines and columns", function()
    dap.with_session(program, function(session)
        session:configure {
            initialize = {
                adapterID = "moonbug-tests",
                linesStartAt1 = false,
                columnsStartAt1 = false,
            },
            breakpoints = {
                { line = repeated_line - 1 },
            },
        }

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(repeated_line - 1, stop.frames[1].line)
        expect.eq(0, stop.frames[1].column)
    end)
end)

test("re-hits a breakpoint in a one-line loop", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = repeated_line },
            },
        }

        local first = session:wait_for_stop "breakpoint"
        expect.eq(repeated_line, first.frames[1].line)
        expect_iteration(session, first, "1")

        dap.assert_success(session:request("continue", {
            threadId = first.thread_id,
        }))

        local second = session:wait_for_stop "breakpoint"
        expect.eq(repeated_line, second.frames[1].line)
        expect_iteration(session, second, "2")

        dap.assert_success(session:request("continue", {
            threadId = second.thread_id,
        }))
    end)
end)
