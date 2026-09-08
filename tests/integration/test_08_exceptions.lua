local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/08_exceptions.lua"
local caught_line = dap.find_marker(program, "caught")
local uncaught_line = dap.find_marker(program, "uncaught")

test("reports caught and uncaught exceptions", function()
    dap.with_session(program, function(session)
        session:configure {
            exception_filters = {
                "error",
                "pcall",
                "uncaught",
            },
        }

        local caught = session:wait_for_stop "exception"
        expect.eq(caught_line, caught.frames[1].line)

        local caught_info = dap.assert_success(session:request("exceptionInfo", {
            threadId = caught.thread_id,
        }))

        expect.eq("error", caught_info.body.exceptionId)
        expect.eq("caught failure", caught_info.body.description)
        expect.eq("always", caught_info.body.breakMode)
        expect.eq("caught failure", caught_info.body.details.message)
        expect.not_nil(caught_info.body.details.stackTrace)

        dap.assert_success(session:request("continue", {
            threadId = caught.thread_id,
        }))
        session:wait_for_event "continued"

        local uncaught = session:wait_for_stop "exception"
        expect.eq(uncaught_line, uncaught.frames[1].line)

        local uncaught_info = dap.assert_success(session:request("exceptionInfo", {
            threadId = uncaught.thread_id,
        }))

        expect.eq("uncaught failure", uncaught_info.body.description)
        expect.eq("unhandled", uncaught_info.body.breakMode)

        dap.assert_success(session:request "terminate")
        session:wait_for_event "terminated"
    end)
end)

test("skips caught exceptions when pcall is disabled", function()
    dap.with_session(program, function(session)
        session:configure {
            exception_filters = {
                "error",
                "uncaught",
            },
        }

        local stop = session:wait_for_stop "exception"
        expect.eq(uncaught_line, stop.frames[1].line)

        dap.assert_success(session:request "terminate")
        session:wait_for_event "terminated"
    end)
end)
