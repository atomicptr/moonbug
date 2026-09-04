local moonbug = require "src.moonbug"
local dap = require "tests.utils_dap"

local p = moonbug._internal

before_each(function()
    p.reset()
end)

local function start(conn, opts)
    p.session.client = conn
    p.session.ready = true
    p.session.paused = true
    p.session.client_args = opts or {}
    p.session.frames = {}
end

---@param peer moonbug.Socket
---@param conn moonbug.Socket
---@param req  table
local function roundtrip(peer, conn, req)
    p.session.client = conn
    p.dispatch(req)
    return dap.read_msg(peer)
end

test("table_variables: indexed filter slices with a 0-based start", function()
    local vars = p.table_variables({ "a", "b", "c", "d", "e" }, "indexed", 1, 2)

    expect.eq(2, #vars)
    expect.eq("[2]", vars[1].name)
    expect.eq("b", vars[1].value)
    expect.eq("[3]", vars[2].name)
    expect.eq("c", vars[2].value)
end)

test("table_variables: indexed filter clamps at both ends", function()
    local t = { "a", "b", "c", "d", "e" }

    expect.eq(2, #p.table_variables(t, "indexed", 3, 5))
    expect.eq(0, #p.table_variables(t, "indexed", 10, 2))
end)

test("table_variables: count 0 or absent means everything", function()
    local t = { "a", "b", "c", "d", "e" }

    expect.eq(5, #p.table_variables(t, "indexed"))
    expect.eq(5, #p.table_variables(t, "indexed", nil, 0))
    expect.eq(4, #p.table_variables(t, "indexed", 1, 0))
end)

test("table_variables: caps long arrays at table_max_items", function()
    local big = {}
    for i = 1, 1200 do
        big[i] = i
    end

    local vars = p.table_variables(big, "indexed")
    expect.eq(999, #vars)
    expect.eq("[1]", vars[1].name)
    expect.eq("[999]", vars[999].name)
end)

test("table_variables: named filter lists sorted, stringified keys", function()
    local t = { 10, 20, 30, z = 1, a = 2, [100] = 5 }

    local vars = p.table_variables(t, "named")
    expect.eq(3, #vars)
    expect.eq("100", vars[1].name)
    expect.eq("5", vars[1].value)
    expect.eq("a", vars[2].name)
    expect.eq("z", vars[3].name)
end)

test("table_variables: no filter walks array then named with combined indexing", function()
    local t = { 10, 20, 30, z = 1, a = 2, [100] = 5 }

    local vars = p.table_variables(t)
    expect.eq(6, #vars)
    expect.eq("[1]", vars[1].name)
    expect.eq("100", vars[4].name)

    local vars2 = p.table_variables(t, nil, 3, 2)
    expect.eq(2, #vars2)
    expect.eq("100", vars2[1].name)
    expect.eq("a", vars2[2].name)
end)

test("variables: table refs honor filter/start/count when paging is supported", function()
    dap.with_socket_pair(function(peer, conn)
        start(conn, { supportsVariablePaging = true })

        p.session.variables.refs[1] = { kind = "table", data = { tbl = { 10, 20, 30, 40 } } }

        local req = {
            type = "request",
            command = "variables",
            seq = 1,
            arguments = { variablesReference = 1, filter = "indexed", start = 1, count = 2 },
        }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)
        expect.eq(2, #resp.body.variables)
        expect.eq("[2]", resp.body.variables[1].name)
        expect.eq("20", resp.body.variables[1].value)
        expect.eq("[3]", resp.body.variables[2].name)
    end)
end)

test("variables: without paging support paging args are ignored", function()
    dap.with_socket_pair(function(peer, conn)
        start(conn)

        p.session.variables.refs[1] = { kind = "table", data = { tbl = { 1, 2, 3, 4, 5 } } }

        local req = {
            type = "request",
            command = "variables",
            seq = 1,
            arguments = { variablesReference = 1, filter = "indexed", start = 3, count = 1 },
        }

        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)
        expect.eq(5, #resp.body.variables)
        expect.eq("[1]", resp.body.variables[1].name)
    end)
end)

test("variables: globals ref excludes _G", function()
    dap.with_socket_pair(function(peer, conn)
        start(conn)

        p.session.variables.refs[1] = { kind = "globals", data = {} }

        local req = { type = "request", command = "variables", seq = 1, arguments = { variablesReference = 1 } }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)

        local by_name_tbl = {}

        for _, v in ipairs(resp.body.variables) do
            by_name_tbl[v.name] = v
        end

        expect.not_nil(by_name_tbl["expect"])
        expect.not_nil(by_name_tbl["print"])
        expect.eq(nil, by_name_tbl["_G"])
    end)
end)

test("variables: locals ref reads a live frame and skips temporaries", function()
    dap.with_socket_pair(function(peer, conn)
        local function scenario()
            start(conn)

            p.session.frames = { [1] = 2 }

            local alpha = "A"
            local beta = 2

            local req = { type = "request", command = "variables", seq = 1, arguments = { variablesReference = 1 } }

            p.session.variables.refs[1] = { kind = "locals", data = { depth = 2 } }
            p.session.client = conn
            p.dispatch(req)

            local resp = dap.read_msg(peer)

            dap.expect_response(resp, req, true)

            local by_name_tbl = {}

            for _, v in ipairs(resp.body.variables) do
                by_name_tbl[v.name] = v
            end

            expect.eq("A", by_name_tbl["alpha"].value)
            expect.eq("2", by_name_tbl["beta"].value)

            for name in pairs(by_name_tbl) do
                expect.eq(false, name:sub(1, 1) == "(", name)
            end
        end
        scenario()
    end)
end)

test("variables: upvalues ref returns captured values", function()
    dap.with_socket_pair(function(peer, conn)
        start(conn)

        local function make()
            local captured = "hi"
            return function()
                return captured
            end
        end

        p.session.variables.refs[1] = { kind = "upvalues", data = { func = make() } }

        local req = { type = "request", command = "variables", seq = 1, arguments = { variablesReference = 1 } }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)

        local by_name_tbl = {}

        for _, v in ipairs(resp.body.variables) do
            by_name_tbl[v.name] = v
        end

        expect.eq("hi", by_name_tbl["captured"].value)
    end)
end)

test("variables: locals ref errors when its frame is gone", function()
    dap.with_socket_pair(function(peer, conn)
        start(conn)

        p.session.variables.refs[1] = { kind = "locals", data = { depth = 999 } }

        local req = { type = "request", command = "variables", seq = 1, arguments = { variablesReference = 1 } }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, false)
        expect.eq("stack frame is no longer valid", resp.message)
    end)
end)

test("variables: unknown reference errors", function()
    dap.with_socket_pair(function(peer, conn)
        start(conn)

        local req = { type = "request", command = "variables", seq = 1, arguments = { variablesReference = 12345 } }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, false)
        expect.eq("invalid variablesReference", resp.message)
    end)
end)

test("scopes: unknown frameId errors", function()
    dap.with_socket_pair(function(peer, conn)
        start(conn)

        local req = { type = "request", command = "scopes", seq = 1, arguments = { frameId = 1 } }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, false)
        expect.eq("invalid frameId", resp.message)
    end)
end)

test("scopes: Local/Upvalue/Global scopes chain into variables", function()
    dap.with_socket_pair(function(peer, conn)
        local function scenario()
            start(conn)

            p.session.frames = { [1] = 2 }

            local alpha = "A"
            local beta = 2

            local req = { type = "request", command = "scopes", seq = 1, arguments = { frameId = 1 } }

            p.session.client = conn
            p.dispatch(req)
            local resp = dap.read_msg(peer)

            dap.expect_response(resp, req, true)
            local scopes = resp.body.scopes

            expect.eq("Local", scopes[1].name)
            expect.eq("locals", scopes[1].presentationHint)
            expect.eq("Global", scopes[#scopes].name)
            expect.eq(true, scopes[1].variablesReference > 0)

            local ref = p.session.variables.refs[scopes[1].variablesReference]
            expect.not_nil(ref)
            expect.eq("locals", ref.kind)

            local req2 = {
                type = "request",
                command = "variables",
                seq = 2,
                arguments = { variablesReference = scopes[1].variablesReference },
            }

            p.dispatch(req2)
            local vars_resp = dap.read_msg(peer)

            dap.expect_response(vars_resp, req2, true)

            local by_name_tbl = {}

            for _, v in ipairs(vars_resp.body.variables) do
                by_name_tbl[v.name] = v
            end

            expect.eq("A", by_name_tbl["alpha"].value)
            expect.eq("2", by_name_tbl["beta"].value)
        end
        scenario()
    end)
end)

test("scopes+variables: nested table variable expands to its children", function()
    dap.with_socket_pair(function(peer, conn)
        local function scenario()
            start(conn)

            p.session.frames = { [1] = 2 }

            local t = { "x", "y", named = 9 }

            local req = { type = "request", command = "scopes", seq = 1, arguments = { frameId = 1 } }

            p.session.client = conn
            p.dispatch(req)
            local scopes_resp = dap.read_msg(peer)

            dap.expect_response(scopes_resp, req, true)

            local req2 = {
                type = "request",
                command = "variables",
                seq = 2,
                arguments = { variablesReference = scopes_resp.body.scopes[1].variablesReference },
            }

            p.dispatch(req2)
            local locals_resp = dap.read_msg(peer)

            dap.expect_response(locals_resp, req2, true)

            local t_var
            for _, v in ipairs(locals_resp.body.variables) do
                if v.name == "t" then
                    t_var = v
                end
            end

            expect.not_nil(t_var)
            expect.eq(true, t_var.variablesReference > 0)
            expect.eq(2, t_var.indexedVariables)
            expect.eq(1, t_var.namedVariables)

            local req3 = {
                type = "request",
                command = "variables",
                seq = 3,
                arguments = { variablesReference = t_var.variablesReference, filter = "indexed" },
            }

            p.dispatch(req3)
            local child_resp = dap.read_msg(peer)

            dap.expect_response(child_resp, req3, true)
            expect.eq(2, #child_resp.body.variables)
            expect.eq("[1]", child_resp.body.variables[1].name)
            expect.eq("x", child_resp.body.variables[1].value)
        end
        scenario()
    end)
end)

test("evaluate: expression resolves against the paused frame", function()
    dap.with_socket_pair(function(peer, conn)
        local function scenario()
            start(conn)

            p.session.frames = { [1] = 2 }

            local x = 10
            local req = {
                type = "request",
                command = "evaluate",
                seq = 1,
                arguments = { frameId = 1, expression = "x + 1", context = "watch" },
            }

            p.session.client = conn
            p.dispatch(req)
            local resp = dap.read_msg(peer)

            dap.expect_response(resp, req, true)
            expect.eq("11", resp.body.result)
            expect.eq("number", resp.body.type)
        end

        scenario()
    end)
end)

test("evaluate: repl assignment writes back into the paused frame", function()
    dap.with_socket_pair(function(peer, conn)
        local mutated
        local function scenario()
            start(conn)

            p.session.frames = { [1] = 2 }

            local value = 1
            local req = {
                type = "request",
                command = "evaluate",
                seq = 1,
                arguments = { frameId = 1, expression = "value = 41", context = "repl" },
            }

            p.session.client = conn
            p.dispatch(req)
            local resp = dap.read_msg(peer)

            dap.expect_response(resp, req, true)
            mutated = value
        end

        scenario()
        expect.eq(41, mutated)
    end)
end)

test("evaluate: read-only contexts reject assignment over DAP", function()
    dap.with_socket_pair(function(peer, conn)
        local mutated
        local function scenario()
            start(conn)

            p.session.frames = { [1] = 2 }

            local value = 1
            local req = {
                type = "request",
                command = "evaluate",
                seq = 1,
                arguments = { frameId = 1, expression = "value = 41", context = "watch" },
            }

            local resp = roundtrip(peer, conn, req)

            dap.expect_response(resp, req, false)
            expect.eq("string", type(resp.message))
            expect.eq(true, #resp.message > 0)
            mutated = value
        end

        scenario()
        expect.eq(1, mutated)
    end)
end)

test("evaluate: unknown frameId errors", function()
    dap.with_socket_pair(function(peer, conn)
        start(conn)

        local req = {
            type = "request",
            command = "evaluate",
            seq = 1,
            arguments = { frameId = 1, expression = "1 + 1" },
        }

        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, false)
        expect.eq("invalid frameId", resp.message)
    end)
end)

test("evaluate: expression errors surface as an error response", function()
    dap.with_socket_pair(function(peer, conn)
        local function scenario()
            start(conn)

            p.session.frames = { [1] = 2 }

            local req = {
                type = "request",
                command = "evaluate",
                seq = 1,
                arguments = { frameId = 1, expression = "1 +", context = "watch" },
            }

            local resp = roundtrip(peer, conn, req)

            dap.expect_response(resp, req, false)
            expect.eq("string", type(resp.message))
        end

        scenario()
    end)
end)

test("serialize_eval_result: single value keeps type, multiple join with tabs", function()
    local single = p.serialize_eval_result({ 11 }, 1)
    expect.eq("11", single.result)
    expect.eq("number", single.type)
    expect.eq(0, single.variablesReference)

    local multi = p.serialize_eval_result({ 7, "x" }, 2)
    expect.eq("7\tx", multi.result)
    expect.eq(0, multi.variablesReference)
end)

test("global_keys is sorted and hides _G", function()
    local keys = p.global_keys()

    expect.eq(true, #keys > 0)

    for i = 2, #keys do
        expect.eq(true, tostring(keys[i - 1]) < tostring(keys[i]))
    end

    for _, k in ipairs(keys) do
        expect.neq("_G", k)
    end
end)
