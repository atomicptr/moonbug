local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/breakpoint_basics.lua"
local breakpoint_line = dap.find_marker(program, "breakpoint")

local function initialize(session)
    local response = dap.assert_success(session:request("initialize", {
        adapterID = "moonbug-tests",
        linesStartAt1 = true,
        columnsStartAt1 = true,
        supportsVariableType = true,
    }))

    session:wait_for_event "initialized"
    return response.body
end

test("negotiates capabilities and completes the attach handshake", function()
    dap.with_session(program, function(session)
        local capabilities = initialize(session)

        expect.is_true(capabilities.supportsConfigurationDoneRequest)
        expect.is_true(capabilities.supportsCompletionsRequest)
        expect.is_true(capabilities.supportsConditionalBreakpoints)
        expect.is_true(capabilities.supportsEvaluateForHovers)
        expect.is_true(capabilities.supportsExceptionInfoRequest)
        expect.is_true(capabilities.supportsHitConditionalBreakpoints)
        expect.is_true(capabilities.supportsLoadedSourcesRequest)
        expect.is_true(capabilities.supportsLogPoints)
        expect.is_true(capabilities.supportsModulesRequest)
        expect.is_true(capabilities.supportsSetVariable)
        expect.is_true(capabilities.supportsSetExpression)
        expect.is_true(capabilities.supportsValueFormattingOptions)
        expect.is_true(capabilities.supportsTerminateRequest)

        dap.assert_success(session:request("attach", {
            project_root_dir = ".",
        }))

        dap.assert_success(session:request "configurationDone")
    end)
end)

test("accepts launch requests and configures breakpoints", function()
    dap.with_session(program, function(session)
        initialize(session)

        dap.assert_success(session:request("launch", {
            project_root_dir = ".",
        }))

        local breakpoints = dap.assert_success(session:request("setBreakpoints", {
            source = { path = program },
            breakpoints = { { line = breakpoint_line } },
        }))

        expect.is_true(breakpoints.body.breakpoints[1].verified)

        dap.assert_success(session:request "configurationDone")

        local stop = session:wait_for_stop "breakpoint"
        expect.eq(breakpoint_line, stop.frames[1].line)
        expect.eq(program, stop.frames[1].source.path)

        dap.assert_success(session:request("continue", {
            threadId = stop.thread_id,
        }))
    end)
end)

test("rejects unsupported requests without blocking initialization", function()
    dap.with_session(program, function(session)
        initialize(session)

        dap.assert_error(session:request "moonbug/unknown", "unsupported command found: moonbug/unknown")

        dap.assert_success(session:request("attach", {
            project_root_dir = ".",
        }))

        dap.assert_success(session:request "configurationDone")
    end)
end)
