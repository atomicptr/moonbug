local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/breakpoint_basics.lua"
local breakpoint_line = dap.find_marker(program, "breakpoint")

test("terminates a stopped debuggee", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = { { line = breakpoint_line } },
        }

        session:wait_for_stop "breakpoint"
        dap.assert_success(session:request "terminate")
        session:wait_for_event "terminated"
    end)
end)

local restart_program = "tests/fixtures/programs/restart.lua"
local restart_breakpoint = dap.find_marker(restart_program, "breakpoint")

test("disconnect with restart accepts a new client", function()
    dap.with_session(restart_program, function(session)
        session:configure {
            breakpoints = { { line = restart_breakpoint } },
        }

        session:wait_for_stop "breakpoint"
        dap.assert_success(session:request("disconnect", { restart = true }))

        session:reconnect()

        dap.assert_success(session:request("initialize", {
            adapterID = "moonbug-tests",
            linesStartAt1 = true,
            columnsStartAt1 = true,
        }))

        session:wait_for_event "initialized"

        dap.assert_success(session:request("attach", {
            project_root_dir = ".",
        }))

        dap.assert_success(session:request("setBreakpoints", {
            source = { path = restart_program },
            breakpoints = { { line = restart_breakpoint } },
        }))

        dap.assert_success(session:request "configurationDone")

        local stop = session:wait_for_stop "breakpoint"

        dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "done = true",
            context = "repl",
        }))

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))

        local output = session:wait_for_event("output", function(body)
            return body.category == "stdout"
        end)

        expect.eq("RESTART_DONE\n", output.body.output)
    end, {
        connect_timeout = 3,
        request_timeout = 2,
        process_timeout = 8,
    })
end)

test("disconnects and lets the debuggee finish", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = { { line = breakpoint_line } },
        }

        session:wait_for_stop "breakpoint"
        dap.assert_success(session:request("disconnect", {}))

        session.process:wait()
        expect.eq("42\n", session.process:output())
    end)
end)
