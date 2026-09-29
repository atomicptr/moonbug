local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/execution.lua"
local start_line = dap.find_marker(program, "start")
local call_line = dap.find_marker(program, "call")
local inside_line = dap.find_marker(program, "inside")
local after_line = dap.find_marker(program, "after")

test("steps through Lua code and pauses running execution", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = start_line },
            },
        }

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(start_line, stop.frames[1].line)

        dap.assert_success(session:request("next", {
            threadId = stop.thread_id,
        }))

        stop = session:wait_for_stop "step"
        expect.eq(call_line, stop.frames[1].line)

        dap.assert_success(session:request("stepIn", {
            threadId = stop.thread_id,
        }))

        stop = session:wait_for_stop "step"
        expect.eq(inside_line, stop.frames[1].line)

        dap.assert_success(session:request("stepOut", {
            threadId = stop.thread_id,
        }))

        stop = session:wait_for_stop "step"
        expect.eq(after_line, stop.frames[1].line)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
        session:wait_for_event "continued"

        for _, command in ipairs {
            "next",
            "stepIn",
            "stepOut",
            "continue",
        } do
            local response = session:request(command, {
                threadId = stop.thread_id,
            })

            dap.assert_error(response, "notStopped")
        end

        dap.assert_success(session:request("pause", {
            threadId = stop.thread_id,
        }))

        local paused = session:wait_for_stop "pause"
        expect.eq(program, paused.frames[1].source.path)

        dap.assert_success(session:request("evaluate", {
            frameId = paused.frame_id,
            expression = "running = false",
            context = "repl",
        }))

        dap.assert_success(session:request("continue", {
            threadId = paused.thread_id,
        }))
        session:wait_for_event "continued"

        local output = session:wait_for_event("output", function(body)
            return body.category == "stdout"
        end)

        expect.eq("EXECUTION_DONE\t13\n", output.body.output)
    end)
end)

local hook_program = "tests/fixtures/programs/hook_depth.lua"
local churn_line = dap.find_marker(hook_program, "after_churn")
local hook_call_line = dap.find_marker(hook_program, "call")
local after_call_line = dap.find_marker(hook_program, "after_call")

test("keeps stepping accurate after caught errors and tail calls", function()
    dap.with_session(hook_program, function(session)
        session:configure {
            exception_filters = {},
            breakpoints = { { line = churn_line } },
        }

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(churn_line, stop.frames[1].line)

        dap.assert_success(session:request("next", {
            threadId = stop.thread_id,
        }))
        stop = session:wait_for_stop "step"
        expect.eq(hook_call_line, stop.frames[1].line)

        dap.assert_success(session:request("next", {
            threadId = stop.thread_id,
        }))
        stop = session:wait_for_stop "step"
        expect.eq(after_call_line, stop.frames[1].line)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))

        local output = session:wait_for_event("output", function(body)
            return body.category == "stdout"
        end)
        expect.eq("HOOK_DEPTH_DONE\t2\n", output.body.output)
    end)
end)
