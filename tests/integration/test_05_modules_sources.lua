local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/05_modules.lua"
local module_name = "tests.fixtures.modules.runtime_module"
local module_path = "tests/fixtures/modules/runtime_module.lua"

local before_line = dap.find_marker(program, "before")
local after_line = dap.find_marker(program, "after")

---@param messages moonbug.dap.ProtocolMessage[]
---@param event_name string
---@param module string
---@return integer?
local function event_index(messages, event_name, module)
    for index, message in ipairs(messages) do
        if
            message.type == "event"
            ---@cast message moonbug.dap.Event
            and message.event == event_name
        then
            local body = message.body or {}

            if event_name == "loadedSource" and body.source and body.source.path == module then
                return index
            end

            if event_name == "module" and body.module and body.module.name == module then
                return index
            end
        end
    end
end

test("reports runtime modules and loaded sources", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = before_line },
                { line = after_line },
            },
        }

        local before = session:wait_for_stop "breakpoint"
        expect.eq(before_line, before.frames[1].line)

        local initial = dap.assert_success(session:request "modules")

        expect.is_nil(dap.by_name(initial.body.modules)[module_name])

        dap.assert_success(session:request("continue", {
            threadId = before.thread_id,
        }))

        local after = session:wait_for_stop "breakpoint"
        expect.eq(after_line, after.frames[1].line)

        local loaded_event = session:wait_for_event("loadedSource", function(body)
            return body.source and body.source.path == module_path
        end)

        expect.eq(module_path, loaded_event.body.source.path)

        local module_event = session:wait_for_event("module", function(body)
            return body.module and body.module.name == module_name
        end)

        expect.eq("new", module_event.body.reason)
        expect.eq("table", module_event.body.module.kind)
        expect.eq(module_path, module_event.body.module.path)

        local loaded_sources = dap.assert_success(session:request "loadedSources")

        local sources = {}
        for _, source in ipairs(loaded_sources.body.sources) do
            sources[source.path] = true
        end

        expect.eq(true, sources[program])
        expect.eq(true, sources[module_path])

        local modules1 = dap.assert_success(session:request "modules")
        local modules2 = dap.assert_success(session:request "modules")

        local row1 = assert(dap.by_name(modules1.body.modules)[module_name])
        local row2 = assert(dap.by_name(modules2.body.modules)[module_name])

        expect.eq(row1.id, row2.id)
        expect.eq(module_path, row1.path)

        local loaded_index = assert(event_index(session.transcript, "loadedSource", module_path))

        local module_index = assert(event_index(session.transcript, "module", module_name))

        expect.eq(true, loaded_index < module_index)

        local module_event_count = 0

        for _, message in ipairs(session.transcript) do
            if
                message.type == "event"
                ---@cast message moonbug.dap.Event
                and message.event == "module"
                and message.body.module.name == module_name
            then
                module_event_count = module_event_count + 1
            end
        end

        expect.eq(1, module_event_count)

        local page = dap.assert_success(session:request("modules", {
            startModule = 1,
            moduleCount = 2,
        }))

        expect.eq(modules1.body.modules[2].id, page.body.modules[1].id)

        expect.eq(modules1.body.modules[3].id, page.body.modules[2].id)

        dap.assert_success(session:request("continue", {
            threadId = after.thread_id,
        }))
    end)
end)
