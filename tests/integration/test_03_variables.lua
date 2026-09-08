local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/03_variables.lua"
local first_line = dap.find_marker(program, "first")
local second_line = dap.find_marker(program, "second")

---@param session moonbug.test.Session
---@param frame_id integer
---@return moonbug.dap.Scope[]
local function get_scopes(session, frame_id)
    local response = dap.assert_success(session:request("scopes", {
        frameId = frame_id,
    }))

    return response.body.scopes
end

---@param session moonbug.test.Session
---@param reference integer
---@param args? table
---@return moonbug.dap.Variable[]
local function get_variables(session, reference, args)
    args = args or {}
    args.variablesReference = reference

    local response = dap.assert_success(session:request("variables", args))

    return response.body.variables
end

test("reports scopes, variables, paging and stale references", function()
    dap.with_session(program, function(session)
        session:configure {
            initialize = {
                adapterID = "moonbug-tests",
                supportsVariablePaging = true,
            },
            breakpoints = {
                { line = first_line },
                { line = second_line },
            },
        }

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(first_line, stop.frames[1].line)

        local scopes = get_scopes(session, stop.frame_id)

        expect.eq("Local", scopes[1].name)
        expect.eq("locals", scopes[1].presentationHint)
        expect.eq("Upvalue", scopes[2].name)
        expect.eq("Global", scopes[3].name)

        local locals = dap.by_name(get_variables(session, scopes[1].variablesReference))

        expect.eq("41", locals.scalar.value)
        expect.eq("number", locals.scalar.type)
        expect.eq(0, locals.scalar.variablesReference)

        expect.eq("table", locals.mixed.type)
        expect.eq(4, locals.mixed.indexedVariables)
        expect.eq(3, locals.mixed.namedVariables)

        local mixed_reference = locals.mixed.variablesReference

        local indexed = get_variables(session, mixed_reference, {
            filter = "indexed",
            start = 1,
            count = 2,
        })

        expect.eq(2, #indexed)
        expect.eq("[2]", indexed[1].name)
        expect.eq("two", indexed[1].value)
        expect.eq("[3]", indexed[2].name)
        expect.eq("three", indexed[2].value)

        local named = get_variables(session, mixed_reference, {
            filter = "named",
            start = 1,
            count = 1,
        })

        expect.eq(1, #named)
        expect.eq("alpha", named[1].name)
        expect.eq("A", named[1].value)

        local upvalues = dap.by_name(get_variables(session, scopes[2].variablesReference))

        expect.eq("captured-value", upvalues.captured.value)

        local globals = dap.by_name(get_variables(session, scopes[3].variablesReference))

        expect.is_nil(globals["_G"])

        expect.not_nil(locals.bad_tostring.value:find("<error:", 1, true))

        local large = get_variables(session, locals.large.variablesReference, { filter = "indexed" })

        expect.eq(999, #large)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))

        session:wait_for_event "continued"

        local second = session:wait_for_stop "breakpoint"
        expect.eq(second_line, second.frames[1].line)

        dap.assert_error(
            session:request("variables", {
                variablesReference = mixed_reference,
            }),
            "invalid variablesReference"
        )

        dap.assert_error(
            session:request("variables", {
                variablesReference = 123456,
            }),
            "invalid variablesReference"
        )

        dap.assert_error(
            session:request("scopes", {
                frameId = 123456,
            }),
            "invalid frameId"
        )

        dap.assert_success(session:request("continue", {
            threadId = second.thread_id,
        }))
    end)
end)

test("ignores paging arguments when paging was not negotiated", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = first_line },
            },
        }

        local stop = session:wait_for_stop "breakpoint"
        local scopes = get_scopes(session, stop.frame_id)

        local locals = dap.by_name(get_variables(session, scopes[1].variablesReference))

        local indexed = get_variables(session, locals.mixed.variablesReference, {
            filter = "indexed",
            start = 3,
            count = 1,
        })

        expect.eq(4, #indexed)
        expect.eq("[1]", indexed[1].name)
        expect.eq("[4]", indexed[4].name)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)
