local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/09_coroutines.lua"
local coroutine_line = dap.find_marker(program, "coroutine")
local suspended_line = dap.find_marker(program, "suspended")
local finished_line = dap.find_marker(program, "finished")

test("reports active, suspended, and finished coroutines", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = coroutine_line },
                { line = suspended_line },
                { line = finished_line },
            },
        }

        local coroutine_stop = session:wait_for_stop "breakpoint"
        expect.eq(coroutine_line, coroutine_stop.frames[1].line)
        expect.neq(1, coroutine_stop.thread_id)

        local initial_threads = dap.assert_success(session:request "threads")

        local initial_by_name = dap.by_name(initial_threads.body.threads)
        expect.not_nil(initial_by_name.main)
        expect.not_nil(initial_by_name["coroutine #1"])

        local coroutine_scopes = dap.assert_success(session:request("scopes", {
            frameId = coroutine_stop.frame_id,
        }))

        local coroutine_locals = dap.assert_success(session:request("variables", {
            variablesReference = coroutine_scopes.body.scopes[1].variablesReference,
        }))

        expect.eq("42", dap.by_name(coroutine_locals.body.variables).value.value)

        dap.assert_success(session:request("continue", {
            threadId = coroutine_stop.thread_id,
        }))

        local suspended_stop = session:wait_for_stop "breakpoint"
        expect.eq(suspended_line, suspended_stop.frames[1].line)

        local suspended_threads = dap.assert_success(session:request "threads")

        local coroutine_thread = assert(dap.by_name(suspended_threads.body.threads)["coroutine #1"])

        local suspended_stack = dap.assert_success(session:request("stackTrace", {
            threadId = coroutine_thread.id,
        }))

        local suspended_frame = suspended_stack.body.stackFrames[1]

        dap.assert_error(
            session:request("evaluate", {
                frameId = suspended_frame.id,
                expression = "value + 1",
                context = "watch",
            }),
            "cannot evaluate in a suspended thread"
        )

        dap.assert_success(session:request("continue", {
            threadId = suspended_stop.thread_id,
        }))

        local finished_stop = session:wait_for_stop "breakpoint"
        expect.eq(finished_line, finished_stop.frames[1].line)

        local final_threads = dap.assert_success(session:request "threads")

        expect.eq(1, #final_threads.body.threads)
        expect.eq("main", final_threads.body.threads[1].name)

        dap.assert_success(session:request("continue", {
            threadId = finished_stop.thread_id,
        }))
    end)
end)
