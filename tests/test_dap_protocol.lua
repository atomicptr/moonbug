local moonbug = require "src.moonbug"
local p = moonbug._internal

local ok_dap, dap = pcall(require, "tests.utils_dap")
if not ok_dap then
    print("skipping test because: " .. dap)
    return
end

local json = require "cjson"

test("parse_content_length reads header", function()
    dap.with_socket_pair(function(peer, conn)
        dap.send_all(peer, "Content-Length: 123\r\n\r\nrest")
        expect.eq(123, p.parse_content_length(conn))
    end)
end)

test("read_message decodes a request", function()
    dap.with_socket_pair(function(peer, conn)
        local msg = { type = "request", command = "initialize", seq = 7 }
        dap.send_all(peer, dap.frame_for(msg))
        dap.assert_msg(msg, p.read_message(conn))
    end)
end)

test("read_message reads sequential messages", function()
    dap.with_socket_pair(function(peer, conn)
        local a = { type = "request", command = "initialize", seq = 1 }
        local b = { type = "request", command = "setBreakpoints", seq = 2 }
        dap.send_all(peer, dap.frame_for(a) .. dap.frame_for(b))
        dap.assert_msg(a, p.read_message(conn))
        dap.assert_msg(b, p.read_message(conn))
    end)
end)

test("send_message emits a correctly framed real frame", function()
    dap.with_socket_pair(function(peer, conn)
        local msg = { type = "request", command = "threads", seq = 3 }
        p.send_message(conn, msg)

        local _, payload, n = dap.read_frame_bytes(peer)
        expect.eq(#json.encode(msg), n)
        dap.assert_msg(msg, json.decode(payload))
    end)
end)

test("send_message then read_message round-trip over real sockets", function()
    dap.with_socket_pair(function(peer, conn)
        local out = { type = "response", command = "initialize", success = true, seq = 1 }
        p.send_message(conn, out) -- debugger -> client
        local _, payload = dap.read_frame_bytes(peer)
        dap.assert_msg(out, json.decode(payload))

        local req = { type = "request", command = "continue", seq = 5 }
        dap.send_all(peer, dap.frame_for(req)) -- client -> debugger
        dap.assert_msg(req, p.read_message(conn))
    end)
end)
