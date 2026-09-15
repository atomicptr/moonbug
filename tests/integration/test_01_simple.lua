local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/01_simple.lua"
local breakpoint_line = dap.find_marker(program, "breakpoint")

test("initializes, stops at breakpoint and continues", function()
    dap.with_session(program, function(session)
        local initialize = session:request("initialize", {
            adapterID = "moonbug-tests",
            linesStartAt1 = true,
            columnsStartAt1 = true,
            supportsVariableType = true,
        })

        expect.eq(true, initialize.success)
        expect.eq(true, initialize.body.supportsConfigurationDoneRequest)

        local initialized = session:wait_for_event "initialized"
        expect.eq("initialized", initialized.event)

        session:request("attach", {
            project_root_dir = ".",
        })

        local breakpoints = session:request("setBreakpoints", {
            source = { path = program },
            breakpoints = {
                { line = breakpoint_line },
            },
        })

        expect.eq(true, breakpoints.body.breakpoints[1].verified)

        session:request "configurationDone"

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(breakpoint_line, stop.frames[1].line)
        expect.eq(program, stop.frames[1].source.path)

        local evaluated = session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "value",
            context = "watch",
        })

        expect.eq("41", evaluated.body.result)

        session:request("continue", {
            threadId = stop.thread_id,
        })
    end)
end)

test("advertises capabilities and terminates a stopped debugger", function()
    dap.with_session(program, function(session)
        local capabilities = session:configure {
            breakpoints = {
                { line = breakpoint_line },
            },
        }

        expect.is_true(capabilities.supportsConfigurationDoneRequest)
        expect.is_true(capabilities.supportsConditionalBreakpoints)
        expect.is_true(capabilities.supportsHitConditionalBreakpoints)
        expect.is_true(capabilities.supportsLogPoints)
        expect.is_true(capabilities.supportsTerminateRequest)

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(breakpoint_line, stop.frames[1].line)

        dap.assert_success(session:request "terminate")

        local terminated = session:wait_for_event "terminated"
        expect.eq("terminated", terminated.event)
    end)
end)

test("returns an error for unsupported commands", function()
    dap.with_session(program, function(session)
        dap.assert_success(session:request("initialize", {
            adapterID = "moonbug-tests",
            linesStartAt1 = true,
            columnsStartAt1 = true,
        }))

        session:wait_for_event "initialized"

        local unsupported = session:request "moonbug/unknown"

        dap.assert_error(unsupported, "unsupported command found: moonbug/unknown")

        dap.assert_success(session:request("attach", {
            project_root_dir = ".",
        }))

        dap.assert_success(session:request("setBreakpoints", {
            source = { path = program },
            breakpoints = {
                { line = breakpoint_line },
            },
        }))

        dap.assert_success(session:request "configurationDone")

        local stop = session:wait_for_stop "breakpoint"

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)

test("supports zero based lines and columns", function()
    dap.with_session(program, function(session)
        local capabilities = session:configure {
            initialize = {
                adapterID = "moonbug-tests",
                linesStartAt1 = false,
                columnsStartAt1 = false,
            },
            breakpoints = {
                { line = breakpoint_line - 1 },
            },
        }

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(breakpoint_line - 1, stop.frames[1].line)
        expect.eq(0, stop.frames[1].column)
    end)
end)
