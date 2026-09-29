local dap = require "tests.dap_session"

local variables_program = "tests/fixtures/programs/variables.lua"
local variables_line = dap.find_marker(variables_program, "first")

local stack_program = "tests/fixtures/programs/value_formatting.lua"
local parameter_line = dap.find_marker(stack_program, "breakpoint")

---@param session moonbug.test.Session
---@param reference integer
---@param args? table
---@return moonbug.dap.Variable[]
local function get_variables(session, reference, args)
    args = args or {}
    args.variablesReference = reference
    return dap.assert_success(session:request("variables", args)).body.variables
end

test("formats variable and evaluate numeric values as hexadecimal", function()
    dap.with_session(variables_program, function(session)
        session:configure {
            breakpoints = { { line = variables_line } },
        }

        local stop = session:wait_for_stop "breakpoint"
        local scopes = dap.assert_success(session:request("scopes", {
            frameId = stop.frame_id,
        })).body.scopes
        local locals = dap.by_name(get_variables(session, scopes[1].variablesReference, {
            format = { hex = true },
        }))
        expect.eq("0x29", locals.scalar.value)

        local large = get_variables(session, locals.large.variablesReference, {
            filter = "indexed",
            start = 0,
            count = 2,
            format = { hex = true },
        })
        expect.eq("0x1", large[1].value)
        expect.eq("0x2", large[2].value)

        local evaluated = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "scalar + 1",
            context = "watch",
            format = { hex = true },
        }))
        expect.eq("0x2a", evaluated.body.result)

        local multiple = dap.assert_success(session:request("evaluate", {
            frameId = stop.frame_id,
            expression = "scalar, scalar + 1",
            context = "watch",
            format = { hex = true },
        }))
        expect.eq("0x29\t0x2a", multiple.body.result)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)

test("formats stack frame parameter details", function()
    dap.with_session(stack_program, function(session)
        session:configure {
            breakpoints = { { line = parameter_line } },
        }

        local stop = session:wait_for_stop "breakpoint"
        local default_stack = dap.assert_success(session:request("stackTrace", {
            threadId = stop.thread_id,
        }))
        local formatted_stack = dap.assert_success(session:request("stackTrace", {
            threadId = stop.thread_id,
            format = {
                parameters = true,
                parameterNames = true,
                parameterTypes = true,
                parameterValues = true,
                hex = true,
                line = true,
                module = true,
                includeAll = true,
            },
        }))

        local frame_name
        for _, frame in ipairs(formatted_stack.body.stackFrames) do
            if frame.name:find("inspect", 1, true) then
                frame_name = frame.name
                break
            end
        end

        local name = assert(frame_name, "formatted stack trace omitted the inspect frame")
        expect.not_nil(name:find("number: number", 1, true))
        expect.not_nil(name:find("0x2", 1, true))
        expect.not_nil(name:find("value_formatting.lua", 1, true))
        expect.not_nil(name:find(":" .. tostring(parameter_line), 1, true))
        expect.is_true(#formatted_stack.body.stackFrames > #default_stack.body.stackFrames)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)
