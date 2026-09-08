local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/06_breakpoints.lua"
local conditional_line = dap.find_marker(program, "conditional")
local hit_line = dap.find_marker(program, "hit")
local logpoint_line = dap.find_marker(program, "logpoint")

---@param session moonbug.test.Session
local function initialize(session)
    dap.assert_success(session:request("initialize", {
        adapterID = "moonbug-tests",
        linesStartAt1 = true,
        columnsStartAt1 = true,
    }))

    session:wait_for_event "initialized"

    dap.assert_success(session:request("attach", {
        project_root_dir = ".",
    }))
end

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
        initialize(session)

        local response = dap.assert_success(session:request("setBreakpoints", {
            source = { path = program },
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
        }))

        expect.eq(3, #response.body.breakpoints)

        for _, breakpoint in ipairs(response.body.breakpoints) do
            expect.is_true(breakpoint.verified)
        end

        dap.assert_success(session:request "configurationDone")

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
        initialize(session)

        local initial = dap.assert_success(session:request("setBreakpoints", {
            source = { path = program },
            breakpoints = {
                { line = conditional_line },
            },
        }))

        expect.is_true(initial.body.breakpoints[1].verified)

        local replacement = dap.assert_success(session:request("setBreakpoints", {
            source = { path = program },
            breakpoints = {
                {},
                { line = hit_line },
            },
        }))

        expect.is_false(replacement.body.breakpoints[1].verified)
        expect.is_true(replacement.body.breakpoints[2].verified)

        dap.assert_success(session:request "configurationDone")

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(hit_line, stop.frames[1].line)

        dap.assert_success(session:request "terminate")
        session:wait_for_event "terminated"
    end)
end)
