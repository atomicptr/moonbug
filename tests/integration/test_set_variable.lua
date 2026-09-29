local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/evaluation.lua"
local breakpoint_line = dap.find_marker(program, "set_variable")

---@param session   moonbug.test.Session
---@param reference integer
---@return table<string, moonbug.dap.Variable>
local function get_variables(session, reference)
    local response = dap.assert_success(session:request("variables", {
        variablesReference = reference,
    }))

    return dap.by_name(response.body.variables)
end

test("sets locals, upvalues, globals, and table entries", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = { { line = breakpoint_line } },
        }

        local stop = session:wait_for_stop "breakpoint"
        local scopes = dap.assert_success(session:request("scopes", {
            frameId = stop.frame_id,
        })).body.scopes

        local local_response = dap.assert_success(session:request("setVariable", {
            variablesReference = scopes[1].variablesReference,
            name = "value",
            value = "false",
        }))

        expect.eq("false", local_response.body.value)
        expect.eq("boolean", local_response.body.type)

        local upvalue_response = dap.assert_success(session:request("setVariable", {
            variablesReference = scopes[2].variablesReference,
            name = "captured",
            value = "30",
        }))

        expect.eq("30", upvalue_response.body.value)

        local global_name = "MOONBUG_TEST_SET_VARIABLE"
        local global_response = dap.assert_success(session:request("setVariable", {
            variablesReference = scopes[3].variablesReference,
            name = global_name,
            value = '"created"',
        }))

        expect.eq('"created"', global_response.body.value)

        local locals = get_variables(session, scopes[1].variablesReference)
        local nested = locals.nested
        expect.not_nil(nested)

        local table_response = dap.assert_success(session:request("setVariable", {
            variablesReference = nested.variablesReference,
            name = "answer",
            value = "99",
        }))

        expect.eq("99", table_response.body.value)
        expect.eq("99", get_variables(session, nested.variablesReference).answer.value)

        dap.assert_error(
            session:request("setVariable", {
                variablesReference = 123456,
                name = "value",
                value = "1",
            }),
            "invalid variablesReference"
        )

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)
