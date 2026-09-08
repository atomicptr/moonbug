local dap = require "tests.dap_session"

local program = "tests/fixtures/programs/11_threads.lua"
local bp1_line = dap.find_marker(program, "bp1")
local bp2_line = dap.find_marker(program, "bp2")
local bp3_line = dap.find_marker(program, "bp3")

test("make sure threads is working", function()
    dap.with_session(program, function(session)
        session:configure {
            breakpoints = {
                { line = bp1_line },
                { line = bp2_line },
                { line = bp3_line },
            },
        }

        session:wait_for_stop "breakpoint"

        local res1 = dap.assert_success(session:request "threads")
        expect.tbl_length(1, res1.body.threads)

        dap.assert_success(session:request "continue")
        session:wait_for_stop "breakpoint"

        local res2 = dap.assert_success(session:request "threads")
        expect.tbl_length(2, res2.body.threads)

        dap.assert_success(session:request "continue")
        session:wait_for_stop "breakpoint"

        local res3 = dap.assert_success(session:request "threads")
        expect.tbl_length(1, res3.body.threads)
    end)
end)
