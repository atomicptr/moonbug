local moonbug = require "src.moonbug"
local dap = require "tests.utils_dap"

local p = moonbug._internal

before_each(function()
    p.reset()
end)

test("handshake completes after configurationDone and marks the session ready", function()
    dap.with_socket_pair(function(peer, conn)
        local requests = {
            { type = "request", command = "initialize", seq = 1, arguments = { adapterID = "tests" } },
            { type = "request", command = "setExceptionBreakpoints", seq = 2, arguments = { filters = { "pcall" } } },
            { type = "request", command = "configurationDone", seq = 3 },
        }

        for _, r in ipairs(requests) do -- buffer everything up front
            dap.send_all(peer, dap.frame_for(r))
        end

        local ok, err = p.handshake(conn, 5)
        expect.eq(true, ok)
        expect.is_nil(err)
        expect.eq(true, p.session.ready)
        expect.eq(true, p.session.client == conn)

        -- replies arrive in dispatch order
        local resp = dap.read_msg(peer) -- initialize response
        dap.expect_response(resp, requests[1], true)
        expect.eq(true, resp.body.supportsConditionalBreakpoints)

        local ev = dap.read_msg(peer) -- initialized event
        expect.eq("event", ev.type)
        expect.eq("initialized", ev.event)

        resp = dap.read_msg(peer) -- setExceptionBreakpoints response
        dap.expect_response(resp, requests[2], true)
        expect.eq(true, p.session.filters.pcall)

        resp = dap.read_msg(peer) -- configurationDone response
        dap.expect_response(resp, requests[3], true)
    end)
end)

test("handshake rejects frames that are not requests", function()
    dap.with_socket_pair(function(peer, conn)
        dap.send_all(peer, dap.frame_for { type = "event", event = "whatever", seq = 1 })

        local ok, err = p.handshake(conn, 5)
        expect.eq(false, ok)
        expect.eq("bad dap request", err)
    end)
end)

test("handshake aborts when the client disconnects mid-handshake", function()
    dap.with_socket_pair(function(peer, conn)
        dap.send_all(peer, dap.frame_for { type = "request", command = "initialize", seq = 1, arguments = {} })
        dap.send_all(peer, dap.frame_for { type = "request", command = "disconnect", seq = 2 })

        local ok, err = p.handshake(conn, 5)
        expect.eq(false, ok)
        expect.eq("disconnected during handshake", err)
    end)
end)
