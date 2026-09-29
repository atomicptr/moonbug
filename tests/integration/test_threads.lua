local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/coroutines.lua"
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

        local coroutine_scopes = dap.assert_success(session:request("scopes", {
            frameId = coroutine_stop.frame_id,
        }))

        local coroutine_locals = dap.assert_success(session:request("variables", {
            variablesReference = coroutine_scopes.body.scopes[1].variablesReference,
        }))

        ---@type moonbug.dap.Variable[]
        local variables = coroutine_locals.body.variables
        expect.eq("42", dap.by_name(variables).value.value)

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

        dap.assert_success(session:request("continue", {
            threadId = finished_stop.thread_id,
        }))
    end)
end)

local thread_program = "tests/fixtures/programs/thread_lifecycle.lua"
local first_thread_line = dap.find_marker(thread_program, "bp1")
local second_thread_line = dap.find_marker(thread_program, "bp2")
local finished_thread_line = dap.find_marker(thread_program, "bp3")

test("reports thread counts as a coroutine starts and exits", function()
    dap.with_session(thread_program, function(session)
        session:configure {
            breakpoints = {
                { line = first_thread_line },
                { line = second_thread_line },
                { line = finished_thread_line },
            },
        }

        session:wait_for_stop "breakpoint"
        local main_only = dap.assert_success(session:request "threads")
        expect.tbl_length(1, main_only.body.threads)
        expect.eq("main", main_only.body.threads[1].name)

        dap.assert_success(session:request "continue")
        session:wait_for_stop "breakpoint"
        local active = dap.assert_success(session:request "threads")
        expect.tbl_length(2, active.body.threads)

        dap.assert_success(session:request "continue")
        session:wait_for_stop "breakpoint"
        local finished = dap.assert_success(session:request "threads")
        expect.tbl_length(1, finished.body.threads)
    end)
end)
