local moonbug = require "src.moonbug"

local dap = moonbug._test.dap

local dap_utils = require "tests.dap_utils"
local json = require "cjson"

test("parse_content_length reads header", function()
    dap_utils.with_socket_pair(function(peer, conn)
        dap_utils.send_all(peer, "Content-Length: 123\r\n\r\nrest")
        expect.eq(123, dap.parse_content_length(conn))
    end)
end)

test("read_message decodes a request", function()
    dap_utils.with_socket_pair(function(peer, conn)
        local msg = { type = "request", command = "initialize", seq = 7 }
        dap_utils.send_all(peer, dap_utils.encode_message(msg))
        dap_utils.assert_msg(msg, dap.read_message(conn))
    end)
end)

test("read_message reads sequential messages", function()
    dap_utils.with_socket_pair(function(peer, conn)
        local a = { type = "request", command = "initialize", seq = 1 }
        local b = { type = "request", command = "setBreakpoints", seq = 2 }
        dap_utils.send_all(peer, dap_utils.encode_message(a) .. dap_utils.encode_message(b))
        dap_utils.assert_msg(a, dap.read_message(conn))
        dap_utils.assert_msg(b, dap.read_message(conn))
    end)
end)

test("read_message tolerates malformed JSON", function()
    dap_utils.with_socket_pair(function(peer, conn)
        dap_utils.send_all(peer, "Content-Length: 7\r\n\r\n{oops!!")
        local msg, err = dap.read_message(conn)
        expect.is_nil(msg)
        expect.not_nil(err)
    end)
end)

test("send_message emits a correctly framed real frame", function()
    dap_utils.with_socket_pair(function(peer, conn)
        local msg = { type = "request", command = "threads", seq = 3 }
        dap.send_message(conn, msg)

        local _, payload, n = dap_utils.read_frame_bytes(peer)
        expect.eq(#json.encode(msg), n)
        dap_utils.assert_msg(msg, json.decode(payload))
    end)
end)

test("payload split across socket writes", function()
    dap_utils.with_socket_pair(function(peer, conn)
        local request = { type = "request", command = "b", seq = 1 }

        local body = json.encode(request)
        local payload = dap_utils.encode_message(request)

        dap_utils.send_all(peer, payload:sub(1, #payload - #body + 3))
        dap_utils.send_all(peer, payload:sub(#payload - #body + 4))
        dap_utils.assert_msg({ type = "request", command = "b", seq = 1 }, dap.read_message(conn))
    end)
end)

test("read_message resumes a header after a timeout", function()
    dap_utils.with_socket_pair(function(peer, conn)
        local request = { type = "request", command = "header-fragment", seq = 1 }
        local body = json.encode(request)
        local header = string.format("Content-Length: %d\r\n\r\n", #body)

        conn:settimeout(0.02)
        dap_utils.send_all(peer, header:sub(1, #header - 4))

        local msg, err = dap.read_message(conn)
        expect.is_nil(msg)
        expect.eq("timeout", err)

        dap_utils.send_all(peer, header:sub(#header - 3) .. body)
        conn:settimeout(2)
        dap_utils.assert_msg(request, dap.read_message(conn))
    end)
end)

test("read_message resumes a payload after a timeout", function()
    dap_utils.with_socket_pair(function(peer, conn)
        local request = { type = "request", command = "payload-fragment", seq = 1 }
        local body = json.encode(request)
        local header = string.format("Content-Length: %d\r\n\r\n", #body)
        local split = math.floor(#body / 2)

        conn:settimeout(0.02)
        dap_utils.send_all(peer, header .. body:sub(1, split))

        local msg, err = dap.read_message(conn)
        expect.is_nil(msg)
        expect.eq("timeout", err)

        dap_utils.send_all(peer, body:sub(split + 1))
        conn:settimeout(2)
        dap_utils.assert_msg(request, dap.read_message(conn))
    end)
end)

test("lowercase content-length header is honored", function()
    dap_utils.with_socket_pair(function(peer, conn)
        local body = json.encode { type = "request", command = "c", seq = 1 }

        dap_utils.send_all(peer, "content-length: " .. #body .. "\r\n\r\n" .. body)
        dap_utils.assert_msg({ type = "request", command = "c", seq = 1 }, dap.read_message(conn))
    end)
end)

test("many back-to-back frames in one write", function()
    dap_utils.with_socket_pair(function(peer, conn)
        local msgs, blob = {}, {}

        for i = 1, 300 do
            msgs[i] = { type = "request", command = "tick", seq = i }
            blob[i] = dap_utils.encode_message(msgs[i])
        end

        dap_utils.send_all(peer, table.concat(blob))

        for i = 1, 300 do
            dap_utils.assert_msg(msgs[i], dap.read_message(conn))
        end
    end)
end)

test("large payload round-trips through send_message", function()
    dap_utils.with_socket_pair(function(peer, conn)
        local body = { vars = {} }

        for i = 1, 40000 do
            body.vars[i] = "value-" .. i
        end

        local msg = { type = "response", command = "big", success = true, body = body }
        dap.send_message(conn, msg)
        local _, payload = dap_utils.read_frame_bytes(peer)
        local decoded = json.decode(payload)
        expect.eq("value-1", decoded.body.vars[1])
        expect.eq("value-40000", decoded.body.vars[40000])
    end)
end)
