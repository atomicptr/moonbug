local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/evaluation.lua"
local breakpoint_line = dap.find_marker(program, "set_variable")

---@param session moonbug.test.Session
---@param expression string
---@param value string
---@param frame_id? integer
---@param format? moonbug.dap.ValueFormat
---@return {
---    value: string,
---    type?: string,
---    presentationHint?: moonbug.dap.VariablePresentationHint,
---    variablesReference?: integer,
---    indexedVariables?: integer,
---    namedVariables?: integer,
---}
local function set_expression(session, expression, value, frame_id, format)
    return dap.assert_success(session:request("setExpression", {
        expression = expression,
        value = value,
        frameId = frame_id,
        format = format,
    })).body
end

---@param session moonbug.test.Session
---@param reference integer
---@return table<string, moonbug.dap.Variable>
local function get_variables(session, reference)
    local response = dap.assert_success(session:request("variables", {
        variablesReference = reference,
    }))
    return dap.by_name(response.body.variables)
end

test("assigns frame and global l-values and returns the assigned value", function()
    dap.with_session(program, function(session)
        session:configure {
            initialize = {
                adapterID = "moonbug-tests",
                supportsVariableType = true,
            },
            breakpoints = { { line = breakpoint_line } },
        }

        local stop = session:wait_for_stop "breakpoint"
        local scopes = dap.assert_success(session:request("scopes", {
            frameId = stop.frame_id,
        })).body.scopes

        local locals = get_variables(session, scopes[1].variablesReference)
        local upvalues = get_variables(session, scopes[2].variablesReference)

        expect.eq("value", locals.value.evaluateName)
        expect.eq("captured", upvalues.captured.evaluateName)

        local nested = locals.nested
        local nested_variables = get_variables(session, nested.variablesReference)
        expect.eq('nested["answer"]', nested_variables.answer.evaluateName)

        local local_result = set_expression(session, locals.value.evaluateName, "value + 32", stop.frame_id)
        expect.eq("42", local_result.value)
        expect.eq("number", local_result.type)
        expect.eq(0, local_result.variablesReference)

        local boolean_result = set_expression(session, locals.value.evaluateName, "false", stop.frame_id)
        expect.eq("false", boolean_result.value)
        expect.eq("boolean", boolean_result.type)

        local upvalue_result = set_expression(session, upvalues.captured.evaluateName, "captured + 1", stop.frame_id)
        expect.eq("21", upvalue_result.value)

        local table_result = set_expression(session, nested_variables.answer.evaluateName, "99", stop.frame_id)
        expect.eq("99", table_result.value)
        expect.eq("99", get_variables(session, nested.variablesReference).answer.value)

        local object_result = set_expression(session, "nested", "{ answer = 100 }", stop.frame_id)
        expect.eq("table", object_result.type)
        expect.neq(0, object_result.variablesReference)
        expect.eq(1, object_result.namedVariables)

        local global_name = "MOONBUG_SET_EXPRESSION_GLOBAL"
        local global_result = set_expression(session, global_name, '"created"')
        expect.eq('"created"', global_result.value)

        local global_readback = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = global_name,
            context = "watch",
        }))

        expect.eq('"created"', global_readback.body.result)

        dap.assert_error(session:request("setExpression", {
            expression = "value + 1",
            value = "0",
            frameId = stop.frame_id,
        }))
        dap.assert_error(
            session:request("setExpression", {
                expression = "value",
                value = "1",
                frameId = 123456,
            }),
            "invalid frameId"
        )

        local hexadecimal = set_expression(session, "value", "42", stop.frame_id, { hex = true })
        expect.eq("0x2a", hexadecimal.value)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)
