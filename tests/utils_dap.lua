local M = {}

local ok_json, json = pcall(require, "cjson")
if not ok_json then
    error "could not find: cjson"
end

local ok_socket, socket = pcall(require, "socket")
if not ok_socket then
    error "could not find: luasocket"
end

---@return moonbug.Socket
---@return moonbug.Socket
function M.socket_pair()
    local server = assert(socket.bind("127.0.0.1", 0))
    server:settimeout(2)
    local ip, port = server:getsockname()
    local peer = assert(socket.connect(ip, port))
    peer:setoption("tcp-nodelay", true)
    local conn = assert(server:accept())
    conn:setoption("tcp-nodelay", true)
    server:close()
    conn:settimeout(2)
    return peer, conn
end

---@param fn fun(peer: moonbug.Socket, conn: moonbug.Socket)
function M.with_socket_pair(fn)
    local peer, conn = M.socket_pair()
    local ok, err = xpcall(fn, debug.traceback, peer, conn)
    peer:close()
    conn:close()
    if not ok then
        error(err, 0)
    end
end

---@param sock moonbug.Socket
---@param data any
function M.send_all(sock, data)
    local sent = 0
    while sent < #data do
        local n = sock:send(data, sent + 1)
        assert(n, "send failed")
        sent = sent + n
    end
end

---@param sock moonbug.Socket
---@param n    integer
---@return string
function M.read_exact(sock, n)
    local parts, left = {}, n
    while left > 0 do
        local chunk, err = sock:receive(left)
        if not chunk then
            error("read_exact: " .. tostring(err))
        end
        parts[#parts + 1] = chunk
        left = left - #chunk
    end
    return table.concat(parts)
end

---@param sock moonbug.Socket
---@return string
---@return string
---@return number
function M.read_frame_bytes(sock)
    local head = ""
    while not head:find("\r\n\r\n", 1, true) do
        head = head .. assert(sock:receive(1))
    end
    local n = assert(tonumber(head:match "Content%-Length: (%d+)"))
    return head, M.read_exact(sock, n), n
end

---@param msg table
---@return string
---@return string
function M.frame_for(msg)
    local payload = json.encode(msg)
    return "Content-Length: " .. #payload .. "\r\n\r\n" .. payload, payload
end

---@param expected? moonbug.dap.ProtocolMessage
---@param actual?   moonbug.dap.ProtocolMessage
function M.assert_msg(expected, actual)
    if expected == nil and actual == nil then
        return
    end

    assert(expected)
    assert(actual)

    expect.eq(expected.type, actual.type)

    if (expected["command"] or nil) or (actual["command"] or nil) then
        ---@cast expected moonbug.dap.Request
        ---@cast actual   moonbug.dap.Request
        expect.eq(expected.command, actual.command)
    end

    expect.eq(expected.seq, actual.seq)
end

---Read one dap message and decode it
---@param sock moonbug.Socket
---@return table
function M.read_msg(sock)
    local _, payload = M.read_frame_bytes(sock)
    return json.decode(payload)
end

function M.read_msg_timeout(sock, timeout)
    sock:settimeout(timeout)

    local ok, msg = pcall(M.read_msg, sock)
    sock:settimeout(0)

    if not ok then
        return nil
    end

    return msg
end

---@param resp     table the decoded response
---@param req      table the request we sent
---@param success  boolean expected `success` flag
function M.expect_response(resp, req, success)
    expect.eq("response", resp.type)
    expect.eq(req.command, resp.command, "request and response command match")
    expect.eq(req.seq, resp.request_seq, "request and response seq match")
    expect.eq(success, resp.success, "response was successful")
end

return M
