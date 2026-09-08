local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/04_evaluate.lua"
local breakpoint_line = dap.find_marker(program, "breakpoint")

test("evaluates locals, upvalues, varargs and multiple results", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = breakpoint_line },
            },
        }

        local stop = session:wait_for_stop "breakpoint"

        local number = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "value + 1",
            context = "watch",
        }))

        expect.eq("11", number.body.result)
        expect.eq("number", number.body.type)
        expect.eq(0, number.body.variablesReference)

        local upvalue = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "captured",
            context = "watch",
        }))

        expect.eq("20", upvalue.body.result)

        local varargs = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = 'select("#", ...)',
            context = "watch",
        }))

        expect.eq("2", varargs.body.result)

        local multiple = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = 'string.find("hello world", "world")',
            context = "watch",
        }))

        expect.eq("7\t11", multiple.body.result)
        expect.is_nil(multiple.body.type)

        local nil_result = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "(function() return nil, 2 end)()",
            context = "watch",
        }))

        expect.eq("nil\t2", nil_result.body.result)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)

test("mutates locals and upvalues only in repl context", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = breakpoint_line },
            },
        }

        local stop = session:wait_for_stop "breakpoint"

        dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "value = 41; captured = 30",
            context = "repl",
        }))

        local values = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "value, captured",
            context = "watch",
        }))

        expect.eq("41\t30", values.body.result)

        local readonly = session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "value = 99",
            context = "watch",
        })

        dap.assert_error(readonly)

        local unchanged = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "value",
            context = "watch",
        }))

        expect.eq("41", unchanged.body.result)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)

test("returns structured compile and runtime errors", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = breakpoint_line },
            },
        }

        local stop = session:wait_for_stop "breakpoint"

        dap.assert_error(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "1 +",
            context = "watch",
        }))

        dap.assert_error(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "error('evaluation failed')",
            context = "watch",
        }))

        dap.assert_error(
            session:request("evaluate", {
                frameId = 123456,
                expression = "1 + 1",
                context = "watch",
            }),
            "invalid frameId"
        )

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)
