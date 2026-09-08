local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/10_hook_depth.lua"
local churn_line = dap.find_marker(program, "after_churn")
local call_line = dap.find_marker(program, "call")
local after_call_line = dap.find_marker(program, "after_call")

test("keeps stepping accurate after caught errors and tail calls", function()
    dap.with_session(program, function(session)
        session:configure {
            exception_filters = {},
            breakpoints = {
                { line = churn_line },
            },
        }

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(churn_line, stop.frames[1].line)

        dap.assert_success(session:request("next", {
            threadId = stop.thread_id,
        }))

        stop = session:wait_for_stop "step"
        expect.eq(call_line, stop.frames[1].line)

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
