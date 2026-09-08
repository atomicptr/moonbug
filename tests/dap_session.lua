---@class moonbug.test.SessionOptions
---@field lua?             string
---@field connect_timeout? number
---@field request_timeout? number
---@field process_timeout? number
---@field coverage?        boolean
---@field config?          moonbug.Config

---@class moonbug.test.Stop
---@field reason string
---@field thread_id integer
---@field frame_id integer
---@field frames moonbug.dap.StackFrame[]

---@class moonbug.test.Session
---@field socket     moonbug.Socket
---@field process    moonbug.test.Process
---@field program    string
---@field next_seq   integer
---@field pending    moonbug.dap.ProtocolMessage[]
---@field transcript moonbug.dap.ProtocolMessage[]
---@field options    moonbug.test.SessionOptions
local M = {}
M.__index = M

local json = require "cjson"
local socket = require "socket"
local dap_utils = require "tests.dap_utils"
local process = require "tests.process"

---@return integer
local function find_free_port()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    server:close()
    return port
end

---@param port integer
---@param timeout number
---@return moonbug.Socket
local function connect(port, timeout)
    local deadline = socket.gettime() + timeout
    local last_error

    repeat
        local client = assert(socket.tcp())
        client:settimeout(0.1)

        local ok, err = client:connect("127.0.0.1", port)
        if ok then
            client:setoption("tcp-nodelay", true)
            client:settimeout(timeout)
            return client
        end

        last_error = err
        client:close()
        socket.sleep(0.02)
    until socket.gettime() >= deadline

    error("could not connect to debuggee: " .. tostring(last_error), 0)
end

---@param message moonbug.dap.ProtocolMessage
---@return boolean
local function is_response(message)
    return message.type == "response"
end

---@param message moonbug.dap.ProtocolMessage
---@return boolean
local function is_event(message)
    return message.type == "event"
end

---@param program string
---@param opts? moonbug.test.SessionOptions
---@return moonbug.test.Session
function M.start(program, opts)
    opts = opts or {}

    local lua = opts.lua or os.getenv "MOONBUG_LUA" or "lua"
    local port = find_free_port()

    local coverage = opts.coverage
    if coverage == nil then
        coverage = package.loaded.luacov ~= nil
    end

    local env = {}

    if opts.config and opts.config.eval_timeout then
        env["MOONBUG_EVAL_TIMEOUT"] = opts.config.eval_timeout
    end

    local p = process.start(lua, "tests/fixtures/launch.lua", port, program, coverage, opts.process_timeout, env)

    local ok, client = pcall(connect, port, opts.connect_timeout or 5)
    if not ok then
        p:kill()
        p:wait()

        local output = p:output()
        os.remove(p.output_path)

        error(tostring(client) .. "\n\nDebuggee output:\n" .. output, 0)
    end

    ---@type moonbug.test.Session
    local instance = {
        socket = client,
        process = p,
        program = program,
        next_seq = 1,
        pending = {},
        transcript = {},
        request_timeout = opts.request_timeout or 5,
        closed = false,
        options = opts,
    }

    return setmetatable(instance, M)
end

---@param command    string
---@param arguments? table
---@return moonbug.dap.Response
function M:request(command, arguments)
    local seq = self.next_seq
    self.next_seq = seq + 1

    ---@type moonbug.dap.Request
    local request = {
        seq = seq,
        type = "request",
        command = command,
        arguments = arguments,
    }

    table.insert(self.transcript, request)
    dap_utils.send_all(self.socket, dap_utils.encode_message(request))

    local message = self:wait_for_message(function(candidate)
        return is_response(candidate)
            ---@cast candidate moonbug.dap.Response
            and candidate.request_seq == seq
    end)

    ---@cast message moonbug.dap.Response
    return message
end

---@param predicate fun(message: moonbug.dap.ProtocolMessage): boolean
---@return moonbug.dap.ProtocolMessage
function M:wait_for_message(predicate)
    for i, message in ipairs(self.pending) do
        if predicate(message) then
            table.remove(self.pending, i)
            return message
        end
    end

    local deadline = socket.gettime() + (self.options.request_timeout or 5)

    while socket.gettime() < deadline do
        self.socket:settimeout(math.max(0.01, deadline - socket.gettime()))

        local ok, message = pcall(dap_utils.decode_message, self.socket)
        if not ok then
            error(self:diagnostic(tostring(message)), 0)
        end

        table.insert(self.transcript, message)

        if predicate(message) then
            return message
        end

        table.insert(self.pending, message)
    end

    error(self:diagnostic "timed out waiting for DAP message", 0)
end

---@param event      string
---@param predicate? fun(body: table): boolean
---@return moonbug.dap.Event
function M:wait_for_event(event, predicate)
    local message = self:wait_for_message(function(candidate)
        if
            not is_event(candidate)
            ---@cast candidate moonbug.dap.Event
            or candidate.event ~= event
        then
            return false
        end

        ---@cast candidate moonbug.dap.Event
        return predicate == nil or predicate(candidate.body or {})
    end)

    ---@cast message moonbug.dap.Event
    return message
end

---@param reason? string
---@return moonbug.test.Stop
function M:wait_for_stop(reason)
    local event = self:wait_for_event("stopped", function(body)
        return reason == nil or body.reason == reason
    end)

    local thread_id = assert(event.body.threadId)
    local response = self:request("stackTrace", {
        threadId = thread_id,
    })

    assert(response.success, response.message)

    local frames = assert(response.body.stackFrames)
    local frame = assert(frames[1], "stopped thread has no stack frames")

    return {
        reason = event.body.reason,
        thread_id = thread_id,
        frame_id = frame.id,
        frames = frames,
    }
end

---@param message string
---@return string
function M:diagnostic(message)
    local lines = { message, "", "=== DAP transcript: ===" }

    for _, item in ipairs(self.transcript) do
        local ok, encoded = pcall(json.encode, item)
        table.insert(lines, ok and encoded or tostring(item))
    end

    local output = self.process:output()
    if output ~= "" then
        table.insert(lines, "")
        table.insert(lines, "=== Debuggee output: ===")
        table.insert(lines, output)
    end

    return table.concat(lines, "\n")
end

---@class moonbug.test.ConfigureOptions
---@field initialize?  moonbug.dap.InitializeRequestArguments
---@field breakpoints? moonbug.dap.SourceBreakpoint[]
---@field exception_filters? string[]

---@param opts? moonbug.test.ConfigureOptions
---@return moonbug.dap.Capabilities
function M:configure(opts)
    opts = opts or {}

    local initialize = opts.initialize or {}
    initialize.adapterID = initialize.adapterID or "moonbug-tests"
    initialize.linesStartAt1 = true
    initialize.columnsStartAt1 = true

    local response = M.assert_success(self:request("initialize", initialize))
    self:wait_for_event "initialized"

    M.assert_success(self:request("attach", {
        project_root_dir = ".",
    }))

    if opts.exception_filters then
        M.assert_success(self:request("setExceptionBreakpoints", {
            filters = opts.exception_filters,
        }))
    end

    if opts.breakpoints then
        M.assert_success(self:request("setBreakpoints", {
            source = { path = self.program },
            breakpoints = opts.breakpoints,
        }))
    end

    M.assert_success(self:request "configurationDone")
    return response.body
end

function M:close()
    pcall(function()
        self:request "terminate"
    end)

    pcall(self.socket.close, self.socket)
    pcall(self.process.close, self.process)
end

---@param path   string
---@param marker string
---@return integer
function M.find_marker(path, marker)
    local file = assert(io.open(path, "r"))

    local line_number = 0
    for line in file:lines() do
        line_number = line_number + 1

        if line:find(string.format("@%s", marker), 1, true) then
            file:close()
            return line_number
        end
    end

    file:close()
    error(string.format("marker %q not found in %s", marker, path), 0)
end

---@param program string
---@param body fun(session: moonbug.test.Session)
---@param opts? moonbug.test.SessionOptions
function M.with_session(program, body, opts)
    local session = M.start(program, opts)
    local ok, err = xpcall(function()
        body(session)
    end, debug.traceback)

    local close_ok, close_err = pcall(function()
        session:close()
    end)

    if not ok then
        ---@cast err string
        error(session:diagnostic(err), 0)
    end

    if not close_ok then
        ---@cast close_err string
        error(session:diagnostic(close_err), 0)
    end
end

---@param response moonbug.dap.Response
---@return moonbug.dap.Response
function M.assert_success(response)
    expect.eq(true, response.success, response.message)
    return response
end

---@param response moonbug.dap.Response
---@param message? string
function M.assert_error(response, message)
    expect.is_false(response.success)

    if message then
        expect.eq(message, response.message, "expected response message")
    end
end

---@generic T: { name: string }
---@param rows T[]
---@return table<string, T>
function M.by_name(rows)
    local result = {}

    for _, row in ipairs(rows) do
        result[row.name] = row
    end

    return result
end

return M
