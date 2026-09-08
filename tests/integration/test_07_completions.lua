local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/07_completions.lua"
local breakpoint_line = dap.find_marker(program, "breakpoint")

---@param targets moonbug.dap.CompletionItem[]
---@return table<string, moonbug.dap.CompletionItem>
local function by_label(targets)
    local result = {}

    for _, target in ipairs(targets) do
        result[target.label] = target
    end

    return result
end

---@param session moonbug.test.Session
---@param frame_id integer
---@param text string
---@return moonbug.dap.CompletionItem[]
local function complete(session, frame_id, text)
    local response = dap.assert_success(session:request("completions", {
        frameId = frame_id,
        text = text,
        column = #text + 1,
    }))

    return response.body.targets
end

test("completes identifiers, fields, methods, and nested values", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = breakpoint_line },
            },
        }

        local stop = session:wait_for_stop "breakpoint"

        local identifiers = by_label(complete(session, stop.frame_id, "completion_"))

        expect.not_nil(identifiers.completion_global)
        expect.not_nil(identifiers.completion_local)
        expect.not_nil(identifiers.completion_upvalue)
        expect.eq(0, identifiers.completion_local.start)
        expect.eq(11, identifiers.completion_local.length)

        local fields = by_label(complete(session, stop.frame_id, "person."))

        expect.eq("field", fields.age.type)
        expect.eq("field", fields.name.type)
        expect.eq("function", fields.greet.type)
        expect.eq("function", fields.grow.type)

        local methods = complete(session, stop.frame_id, "person:gr")

        expect.eq(2, #methods)
        expect.eq("greet", methods[1].label)
        expect.eq("grow", methods[2].label)
        expect.eq(7, methods[1].start)
        expect.eq(2, methods[1].length)

        local nested = complete(session, stop.frame_id, "wrapper.person:gr")

        expect.eq(2, #nested)
        expect.eq("greet", nested[1].label)
        expect.eq("grow", nested[2].label)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
        session:wait_for_event "continued"

        local running = dap.assert_success(session:request("completions", {
            text = "person.",
            column = 8,
        }))

        expect.eq(0, #running.body.targets)

        dap.assert_success(session:request("pause", {
            threadId = stop.thread_id,
        }))

        local paused = session:wait_for_stop "pause"

        dap.assert_success(session:request("evaluate", {
            frameId = paused.frame_id,
            expression = "running = false",
            context = "repl",
        }))

        dap.assert_success(session:request("continue", {
            threadId = paused.thread_id,
        }))
    end)
end)
