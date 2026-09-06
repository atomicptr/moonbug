local moonbug = require "src.moonbug"
local dap = require "tests.utils_dap"

local p = moonbug._internal

before_each(function()
    p.reset()
end)

---@param peer moonbug.Socket
---@param conn moonbug.Socket
---@param req  table
local function roundtrip(peer, conn, req)
    p.session.client = conn
    p.dispatch(req)
    return dap.read_msg(peer)
end

test("a suspended coroutine shows up as a thread", function()
    dap.with_socket_pair(function(peer, conn)
        local co = coroutine.create(function()
            coroutine.yield()
        end)

        coroutine.resume(co)

        p.get_context(co)

        local req = {
            type = "request",
            command = "threads",
            seq = 1,
        }

        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)

        local by_id = {}
        for _, t in ipairs(resp.body.threads) do
            by_id[t.id] = t.name
        end

        expect.eq("main", by_id[1])
        expect.eq("coroutine #1", by_id[2])
    end)
end)

test("stackTrace of a suspended coroutine enumerates its user frames", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.ready = true
        p.session.paused = true
        p.session.client_args = {
            adapterID = "test",
        }

        local co = coroutine.create(function()
            local function inner()
                local bbb = 222
                coroutine.yield()

                return bbb
            end

            local aaa = 111
            inner()

            return aaa
        end)

        coroutine.resume(co)

        p.get_context(co)

        local req = {
            type = "request",
            command = "stackTrace",
            seq = 1,
            arguments = { threadId = 2 },
        }

        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)

        expect.eq(2, resp.body.totalFrames, "inner + the coroutine chunk")

        local top_id = resp.body.stackFrames[1].id

        local scopes_req = {
            type = "request",
            command = "scopes",
            seq = 2,
            arguments = { frameId = top_id },
        }

        local scopes = roundtrip(peer, conn, scopes_req)

        dap.expect_response(scopes, scopes_req, true)

        local vars_req = {
            type = "request",
            command = "variables",
            seq = 3,
            arguments = { variablesReference = scopes.body.scopes[1].variablesReference },
        }

        local vars = roundtrip(peer, conn, vars_req)

        dap.expect_response(vars, vars_req, true)

        local found
        for _, v in ipairs(vars.body.variables) do
            if v.name == "bbb" then
                found = v
            end
        end

        expect.not_nil(found)
        expect.eq("222", found.value)

        local eval_req = {
            type = "request",
            command = "evaluate",
            seq = 4,
            arguments = { frameId = top_id, expression = "bbb + 1" },
        }

        local eval = roundtrip(peer, conn, eval_req)

        dap.expect_response(eval, eval_req, false)
        expect.eq("cannot evaluate in a suspended thread", eval.message)
    end)
end)

test("finished coroutines are purged from the thread list", function()
    dap.with_socket_pair(function(peer, conn)
        local co = coroutine.create(function() end)
        coroutine.resume(co) -- runs to completion

        p.get_context(co)

        local req = {
            type = "request",
            command = "threads",
            seq = 1,
        }

        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)

        expect.eq(1, #resp.body.threads)
        expect.eq("main", resp.body.threads[1].name)
    end)
end)
