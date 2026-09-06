-- moonbug debugger - https://github.com/atomicptr/moonbug
--
-- Copyright 2026 Christopher Kaster <me@atomicptr.de>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
-- documentation files (the “Software”), to deal in the Software without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
-- to permit persons to whom the Software is furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all copies or substantial portions
-- of the Software.
--
-- THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
-- THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
local M = {}

local version = { 0, 1, 0 }
local default_port = 8888

-- for performance reasons we cap the amount of items a table can render
local table_max_items = 999

-- instruction budget between timeout checks during `evaluate`
local eval_count_budget = 50000

-- default seconds before `evaluate` is aborted
local eval_default_timeout = 5

---@type moonbug.dap.Capabilities
local server_capabilities = {
    supportsConditionalBreakpoints = true,
    supportsConfigurationDoneRequest = true,
    supportsEvaluateForHovers = true,
    supportsExceptionInfoRequest = true,
    supportsHitConditionalBreakpoints = true,
    supportsLogPoints = true,
    supportsTerminateRequest = true,
    exceptionBreakpointFilters = {
        { filter = "error", label = "error(...) / assert(...)", default = true },
        { filter = "pcall", label = "caught by pcall(...) / resume(...)", default = false },
        { filter = "uncaught", label = "uncaught errors", default = true },
    },
}

local hidden_keys = {
    ["_G"] = true,
    ["_ENV"] = true,
}

M.version = table.concat(version, ".")

-- for filtering out moonbug from stack traces
local self_src = debug.getinfo(1, "S").source

-- forward declarations
local debug_hook
local remove_debug_hook
local uninstall_wrappers

-- since we're overriding them later we should store them
local assert = assert
local error = error
local pcall = pcall
local print = print
local xpcall = xpcall
local coroutine_create = coroutine.create
local coroutine_wrap = coroutine.wrap
local coroutine_resume = coroutine.resume

-- luajit: Turn off jit
if jit and jit.off then
    jit.off()
end

----> Compatibility & Polyfills
local _json = (function()
    if _G["json"] and _G["json"].encode and _G["json"].decode then
        return _G["json"]
    end

    local ok, cjson = pcall(require, "cjson")
    if not ok then
        error "moonbug: could not find dependency: `cjson`"
    end

    return cjson
end)()

local _socket = (function()
    if _G["socket"] and _G["socket"].bind and _G["socket"].gettime then
        return _G["socket"]
    end

    local ok, luasocket = pcall(require, "socket")
    if not ok then
        error "moonbug: could not find dependency: `socket` (luasocket)"
    end

    return luasocket
end)()

local _unpack = table.unpack or unpack

local _loadstring = loadstring
if not _loadstring then
    _loadstring = function(str, chunkname)
        return load(str, chunkname)
    end
end

---@class moonbug.Socket
---@field settimeout fun(self, value?: number, mode?: "b"|"t"): number, string
---@field close      fun(self): number
---@field bind       fun(self, address: string, port: integer): integer, string
---@field connect    fun(self, address: string, port: integer): integer, string
---@field listen     fun(self, backlog?: integer): integer, string
---@field accept     fun(self): moonbug.Socket, string
---@field send       fun(self, data: string, i?: integer, j?: integer): integer, string, integer
---@field receive    fun(self, pattern?: integer|"*l"|"*a", prefix?: string): string, string, string
---@field shutdown   fun(self, mode: "receive"|"send"|"both"): integer, string
---@field setoption  fun(self, option: "keepalive"|"reuseaddr"|"tcp-nodelay"|"linger", value?: any): integer, string

---@class moondebug.Compat
---@field unpack         fun(list: table, i?: integer, j?: integer): ...
---@field pack           fun(...: any): { n: integer, [integer]: any }
---@field json_encode    fun(v: any): string|nil
---@field json_decode    fun(s: string): any
---@field json_empty     fun(tbl?: table): table
---@field loadstring     fun(text: string, chunkname?: string): (fun(): any)?|string
---@field socket_bind    fun(host: string, port: integer): moonbug.Socket
---@field socket_gettime fun(): integer
---@field log_fatal      fun(message: string)
---@field log_print      fun(message: string)
---@field getenv         fun(var: string): string|nil
---@field setfenv        fun(fn: function, env: table): function
---@field tostring       fun(v: any): string

---@type moondebug.Compat
M.compat = {
    unpack = _unpack,
    pack = table.pack or function(...)
        return { n = select("#", ...), ... }
    end,
    json_encode = _json.encode,
    json_decode = _json.decode,
    json_empty = function(tbl)
        tbl = tbl or {}

        if #tbl ~= 0 then
            return tbl
        end

        return _json.empty_array or {}
    end,
    loadstring = _loadstring,
    socket_bind = _socket.bind,
    socket_gettime = _socket.gettime,
    log_fatal = error,
    log_print = print,
    getenv = os.getenv,
    setfenv = _G.setfenv or function(fn, env)
        assert(type(fn) == "function")
        assert(type(env) == "table")

        local i = 1

        while true do
            local name, _ = debug.getupvalue(fn, i)
            if not name then
                break
            end

            if name == "_ENV" then
                debug.setupvalue(fn, i, env)
                break
            end

            i = i + 1
        end

        return fn
    end,
    tostring = tostring,
}

----> Logger

---@enum moonbug.LogLevel
local log_level = {
    trace = 1,
    debug = 2,
    info = 3,
    warning = 4,
    error = 5,
    fatal = 6,
    off = 99,
}

M.min_log_level = log_level[M.compat.getenv "MOONBUG_LOG" or "info"] or log_level.info

---@param level moonbug.LogLevel
---@return string
local function log_level_to_string(level)
    if level == log_level.trace then
        return "trc"
    elseif level == log_level.debug then
        return "dbg"
    elseif level == log_level.info then
        return "inf"
    elseif level == log_level.warning then
        return "wrn"
    elseif level == log_level.error then
        return "err"
    elseif level == log_level.fatal then
        return "ftl"
    elseif level == log_level.off then
        return "off"
    end

    error("unknown log level: " .. M.compat.tostring(level))
end

---@param level moonbug.LogLevel
---@param fmt   string
---@param ...   any
local function print_log(level, fmt, ...)
    if level < M.min_log_level then
        return
    end

    local message = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    local output = string.format("moonbug:%s: %s", log_level_to_string(level), message)

    if level == log_level.fatal then
        M.compat.log_fatal(output)
        return
    end

    M.compat.log_print(output)
end

local log = {
    trace = function(fmt, ...)
        print_log(log_level.trace, fmt, ...)
    end,
    debug = function(fmt, ...)
        print_log(log_level.debug, fmt, ...)
    end,
    info = function(fmt, ...)
        print_log(log_level.info, fmt, ...)
    end,
    warning = function(fmt, ...)
        print_log(log_level.warning, fmt, ...)
    end,
    error = function(fmt, ...)
        print_log(log_level.error, fmt, ...)
    end,
    fatal = function(fmt, ...)
        print_log(log_level.fatal, fmt, ...)
    end,
}

----> Helpers

---Is this a user frame (e.g. not from the debugger or a C frame)
---@param info debuginfo
---@return boolean
local function is_user_frame(info)
    return info.what ~= "C" and info.source ~= self_src
end

---Returns true if passed a pseudo or temp variable
---@param name string
---@return boolean
local function is_pseudo_variable(name)
    return name:sub(1, 1) == "("
end

---@param v any
---@return string
local function safe_tostring(v)
    local ok, res = pcall(M.compat.tostring, v)
    if ok then
        return res
    end

    return string.format("<error: %s>", M.compat.tostring(res))
end

---Creates a slice from a list, index is 0 based
---@generic T
---@param list         T[]
---@param start_index? integer
---@param count?       integer
---@return any
local function slice(list, start_index, count)
    -- no start and no limit: return the list as is
    -- also according to spec, when count is 0 we should return everything
    -- which we do... unless start index is set
    if not start_index and (count == nil or count == 0) then
        return list
    end

    start_index = start_index or 0
    count = (count == nil or count == 0) and (#list - start_index) or count

    if count <= 0 then
        return {}
    end

    local out = {}

    for i = start_index + 1, math.min(start_index + count, #list) do
        table.insert(out, list[i])
    end

    return out
end

---@param tbl table
---@return integer
local function table_array_length(tbl)
    local n = 0

    while rawget(tbl, n + 1) ~= nil do
        n = n + 1
    end

    return n
end

---@param tbl    table
---@param length integer
---@return string[]
local function table_named_keys(tbl, length)
    local keys = {}

    for k in pairs(tbl) do
        if not (type(k) == "number" and k >= 1 and k <= length) then
            table.insert(keys, k)
        end
    end

    table.sort(keys, function(a, b)
        return safe_tostring(a) < safe_tostring(b)
    end)

    return keys
end

---@param tbl    table
---@param length integer
---@return integer
local function table_named_count(tbl, length)
    local n = 0

    -- NOTE: keep the same as `table_named_keys`
    for k in pairs(tbl) do
        if not (type(k) == "number" and k >= 1 and k <= length) then
            n = n + 1
        end
    end

    return n
end

----> Debug Adapter Protocol

---@enum moonbug.DapCommand
local dap_cmds = {
    attach = "attach",
    configuration_done = "configurationDone",
    continue_ = "continue",
    disconnect = "disconnect",
    evaluate = "evaluate",
    exception_info = "exceptionInfo",
    initialize = "initialize",
    launch = "launch",
    next_ = "next",
    pause = "pause",
    scopes = "scopes",
    set_breakpoints = "setBreakpoints",
    set_exception_breakpoints = "setExceptionBreakpoints",
    stack_trace = "stackTrace",
    step_in = "stepIn",
    step_out = "stepOut",
    terminate = "terminate",
    threads = "threads",
    variables = "variables",
}

---@enum moonbug.DapEvent
local dap_events = {
    continued = "continued",
    initialized = "initialized",
    output = "output",
    stopped = "stopped",
    terminated = "terminated",
}

---@class moonbug.dap.ProtocolMessage
---@field seq  integer
---@field type "request"|"response"|"event"|string

---@class moonbug.dap.Request : moonbug.dap.ProtocolMessage
---@field type       "request"
---@field command    string
---@field arguments? table

---@class moonbug.dap.Event : moonbug.dap.ProtocolMessage
---@field type  "event"
---@field event string
---@field body? any

---@class moonbug.dap.Response : moonbug.dap.ProtocolMessage
---@field type        "response"
---@field request_seq integer
---@field success     boolean
---@field command     string
---@field message?    "cancelled"|"notStopped"|string
---@field body?       any

---@class moonbug.dap.ErrorResponse : moonbug.dap.Response
---@field body { error?: moonbug.dap.Message }

---@class moonbug.dap.Message
---@field id         integer
---@field format     string
---@field variables? table<string, string>

---@class moonbug.dap.Variable
---@field name                string
---@field value               string
---@field type?               string
---@field variablesReference  integer
---@field indexedVariables?   integer
---@field namedVariables?     integer

---@class moonbug.dap.Scope
---@field name                string
---@field variablesReference? integer
---@field presentationHint?   "arguments"|"locals"|"registers"|"returnValue"|string
---@field expensive           boolean

---@class moonbug.dap.ExceptionBreakpointsFilter
---@field filter       string
---@field label        string
---@field description? string
---@field default?     boolean

---@class moonbug.dap.ColumnDescriptor
---@field attributeName string
---@field label         string
---@field format?       string
---@field type?         "string"|"number"|"boolean"|"unixTimestampUTC"
---@field width?        integer

---@alias moonbug.dap.ChecksumAlgorithm "MD5"|"SHA1"|"SHA256"|"timestamp"

---@class moonbug.dap.BreakpointMode
---@field mode         string
---@field label        string
---@field description? string
---@field appliesTo    "source"|"exception"|"instruction"|"string"

---@class moonbug.dap.Source
---@field name? string Short name of the source
---@field path? string Path of the source shown in UI

---@class moonbug.dap.Capabilities
---@field supportsConfigurationDoneRequest?      boolean Supports `configurationDone` request.
---@field supportsFunctionBreakpoints?           boolean Supports function breakpoints.
---@field supportsConditionalBreakpoints?        boolean Supports conditional breakpoints.
---@field supportsHitConditionalBreakpoints?     boolean Supports hit-conditional breakpoints.
---@field supportsEvaluateForHovers?             boolean Supports side-effect free `evaluate` for hovers.
---@field exceptionBreakpointFilters?            moonbug.dap.ExceptionBreakpointsFilter[]
---@field supportsStepBack?                      boolean Supports `stepBack` and `reverseContinue`.
---@field supportsSetVariable?                   boolean Supports setting variable values.
---@field supportsRestartFrame?                  boolean Supports restarting a frame.
---@field supportsGotoTargetsRequest?            boolean Supports `gotoTargets` request.
---@field supportsStepInTargetsRequest?          boolean Supports `stepInTargets` request.
---@field supportsCompletionsRequest?            boolean Supports `completions` request.
---@field completionTriggerCharacters?           string[] REPL completion trigger characters (default `.`).
---@field supportsModulesRequest?                boolean Supports `modules` request.
---@field additionalModuleColumns?               moonbug.dap.ColumnDescriptor[] Additional module information columns.
---@field supportedChecksumAlgorithms?           moonbug.dap.ChecksumAlgorithm[] Supported checksum algorithms.
---@field supportsRestartRequest?                boolean Supports `restart` request.
---@field supportsExceptionOptions?              boolean Supports `exceptionOptions` on `setExceptionBreakpoints`.
---@field supportsValueFormattingOptions?        boolean Supports `format` attribute on evaluation/variables/stackTrace.
---@field supportsExceptionInfoRequest?          boolean Supports `exceptionInfo` request.
---@field supportTerminateDebuggee?              boolean Supports `terminateDebuggee` on `disconnect`.
---@field supportSuspendDebuggee?                boolean Supports `suspendDebuggee` on `disconnect`.
---@field supportsDelayedStackTraceLoading?      boolean Supports delayed loading of stack frames.
---@field supportsLoadedSourcesRequest?          boolean Supports `loadedSources` request.
---@field supportsLogPoints?                     boolean Supports log points via `logMessage`.
---@field supportsTerminateThreadsRequest?       boolean Supports `terminateThreads` request.
---@field supportsSetExpression?                 boolean Supports `setExpression` request.
---@field supportsTerminateRequest?              boolean Supports `terminate` request.
---@field supportsDataBreakpoints?               boolean Supports data breakpoints.
---@field supportsReadMemoryRequest?             boolean Supports `readMemory` request.
---@field supportsWriteMemoryRequest?            boolean Supports `writeMemory` request.
---@field supportsDisassembleRequest?            boolean Supports `disassemble` request.
---@field supportsCancelRequest?                 boolean Supports `cancel` request.
---@field supportsBreakpointLocationsRequest?    boolean Supports `breakpointLocations` request.
---@field supportsClipboardContext?              boolean Supports `clipboard` context in `evaluate`.
---@field supportsSteppingGranularity?           boolean Supports stepping granularity argument.
---@field supportsInstructionBreakpoints?        boolean Supports instruction-based breakpoints.
---@field supportsExceptionFilterOptions?        boolean Supports `filterOptions` on `setExceptionBreakpoints`.
---@field supportsSingleThreadExecutionRequests? boolean Supports `singleThread` execution requests.
---@field supportsDataBreakpointBytes?           boolean Supports `asAddress` and `bytes` in `dataBreakpointInfo`.
---@field breakpointModes?                       moonbug.dap.BreakpointMode[] Supported breakpoint modes.
---@field supportsANSIStyling?                   boolean Supports ANSI escape sequences in output/variable fields.

---@class moonbug.dap.InitializeRequestArguments
---@field clientID?                            string ID of client using adapter.
---@field clientName?                          string Human-readable name of client.
---@field adapterID                            string ID of debug adapter.
---@field locale?                              string ISO-639 locale (e.g. `en-US`, `de-CH`).
---@field linesStartAt1?                       boolean If true, line numbers are 1-based (default).
---@field columnsStartAt1?                     boolean If true, column numbers are 1-based (default).
---@field pathFormat?                          "path"|"uri"|string Format for paths (default `"path"`).
---@field supportsVariableType?                boolean Supports `type` attribute for variables.
---@field supportsVariablePaging?              boolean Supports variable paging.
---@field supportsRunInTerminalRequest?        boolean Supports `runInTerminal` request.
---@field supportsMemoryReferences?            boolean Supports memory references.
---@field supportsProgressReporting?           boolean Supports progress reporting.
---@field supportsInvalidatedEvent?            boolean Supports `invalidated` event.
---@field supportsMemoryEvent?                 boolean Supports `memory` event.
---@field supportsArgsCanBeInterpretedByShell? boolean Supports `argsCanBeInterpretedByShell` on `runInTerminal`.
---@field supportsStartDebuggingRequest?       boolean Supports `startDebugging` request.
---@field supportsANSIStyling?                 boolean Interprets ANSI escape sequences in output/variable fields.

---@param client moonbug.Socket
---@return integer?
---@return string?
local function parse_content_length(client)
    assert(client, "socket client can't be nil")
    local content_length = nil

    while true do
        local line, err = client:receive "*l"
        if not line then
            if err == "closed" then
                return nil, "closed"
            elseif err == "timeout" then
                return nil, "timeout"
            end

            log.error("socket read error: %s", M.compat.tostring(err))
            return nil, err
        end

        -- dap headers end with an empty line
        if line == "" then
            break
        end

        local length_str = line:match "^content%-length%s*:%s*(%d+)%s*$"
        if not length_str then
            -- fallback matching for case insensitive
            length_str = line:lower():match "^content%-length%s*:%s*(%d+)%s*$"
        end

        if length_str then
            content_length = tonumber(length_str)
        end
    end

    return content_length, nil
end

---@param client moonbug.Socket
---@return moonbug.dap.ProtocolMessage?
---@return string?
local function read_message(client)
    assert(client, "socket client can't be nil")

    local length, length_err = parse_content_length(client)
    if length_err ~= nil then
        return nil, length_err
    end

    local payload, payload_err = client:receive(length)
    if not payload then
        log.error("failed to read payload of length %d: %s", length, M.compat.tostring(payload_err))
        return nil, payload_err
    end

    log.trace("read_message(%d): %s", length, payload)

    local ok, decoded = pcall(M.compat.json_decode, payload)
    if not ok then
        return nil, "malformed payload"
    end

    return decoded, nil
end

---@param client moonbug.Socket
---@param message moonbug.dap.ProtocolMessage
local function send_message(client, message)
    assert(client, "socket client can't be nil")

    local json_str = M.compat.json_encode(message)
    local length = #json_str
    local frame = string.format("Content-Length: %d\r\n\r\n%s", length, json_str)

    log.trace("send_message(%d): %s", length, json_str)

    local total_sent = 0
    while total_sent < #frame do
        local sent, err, partial_sent = client:send(frame, total_sent + 1)
        if not sent then
            if err == "timeout" then
                total_sent = partial_sent
            else
                log.error("socket send error: %s", M.compat.tostring(err))
                return
            end
        else
            total_sent = sent
        end
    end
end

----> pathlib

---@param p string
---@return boolean
local function path_is_absolute(p)
    return p:sub(1, 1) == "/" or p:match "^%a+:" ~= nil
end

---@param ... string
---@return string
local function path_join(...)
    local args = { ... }
    local result = {}

    for i = 1, select("#", ...) do
        local part = args[i]
        if part and part ~= "" then
            table.insert(result, part)
        end
    end

    local res = table.concat(result, "/"):gsub("//+", "/")
    return res
end

---@param p string
---@return string
local function path_normalize(p)
    if not p or p == "" then
        return ""
    end

    p = p:gsub("^@", ""):gsub("\\", "/")

    local is_posix = p:sub(1, 1) == "/"
    local parts = {}

    for part in p:gmatch "[^/]+" do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." and part ~= ":" then
            table.insert(parts, part)
        end
    end

    local result = table.concat(parts, "/")
    if path_is_absolute(p) then
        return is_posix and ("/" .. result) or result
    end

    return result
end

local function path_resolve(target, root_dir)
    local cleaned = target:gsub("^@", "")

    if path_is_absolute(cleaned) or not root_dir or root_dir == "" then
        return path_normalize(cleaned)
    end

    return path_normalize(path_join(root_dir, cleaned))
end

----> Debugger

---@class moonbug.Config
---@field wait?           boolean Block until debugger attaches
---@field max_wait_time?  integer Maximum amount of time to wait for things to happen
---@field stop_on_entry?  boolean Stop the process when debugger configuration is done
---@field stop_on_attach? boolean Stop the process when debugger attaches
---@field eval_timeout?   number  Seconds before `evaluate` is aborted (default: 5)
---@field forward_output? boolean Forward print() to the debug console while attached (default: true)

---@alias moonbug.VariableKind "locals"|"globals"|"upvalues"|"table"

---@class moonbug.Breakpoint
---@field condition?     string  The breakpoint condition
---@field hit_condition? string  Hit breakpoint condition
---@field hit_count?     integer Hit counter for hit_condition
---@field log_message?   string  A log message that will be printed instead of stopping

---@class moonbug.ThreadContext
---@field id          integer
---@field name        string
---@field base_depth? integer
---@field stack_level integer
---@field frames      table<integer, integer>
---@field exception?  { message: string, caught: boolean }

---@class moonbug.MainThread

---@alias moonbug.ThreadHandle moonbug.MainThread|thread

---@class moonbug.Session
---@field client?             moonbug.Socket
---@field server?             moonbug.Socket
---@field seq                 integer
---@field ready               boolean True after `configurationDone`
---@field paused              boolean
---@field context             table<moonbug.ThreadHandle, moonbug.ThreadContext>
---@field step?               "in"|"over"|"out"|"pause"|"entry"
---@field step_level          integer
---@field step_thread?        moonbug.ThreadHandle
---@field breakpoints         table<string, table<integer, moonbug.Breakpoint>>
---@field filters             { error: boolean, pcall: boolean, uncaught: boolean }
---@field client_args?        moonbug.dap.InitializeRequestArguments
---@field config?             moonbug.Config
---@field project_root_dir?   string
---@field variables           { next_id: integer, refs: table<integer, { kind: moonbug.VariableKind, data: table }> }
---@field next_frame_id       integer
---@field terminate_requested boolean
local session = {
    seq = 0,
    ready = false,
    paused = false,
    step_level = 0,
    breakpoints = {},
    filters = {
        error = true,
        pcall = false,
        uncaught = true,
    },
    variables = {
        next_id = 1,
        refs = {},
    },
    terminate_requested = false,
}

---@type moonbug.MainThread
local main_thread = {}
local main_thread_id = 1
local next_thread_id = 2

local function session_reset()
    session.seq = 0
    session.ready = false
    session.paused = false
    session.step = nil
    session.step_level = 0
    session.step_thread = nil
    session.breakpoints = {}
    session.filters = { error = true, pcall = false, uncaught = true }
    session.variables = { next_id = 1, refs = {} }
    session.client_args = nil
    session.config = nil
    session.project_root_dir = nil
    session.next_frame_id = 1
    session.terminate_requested = false

    next_thread_id = 2

    session.context = setmetatable({
        [main_thread] = {
            id = main_thread_id,
            name = "main",
            base_depth = 0,
            stack_level = 0,
            frames = {},
        },
    }, { __mode = "k" })

    if session.client and session.client.close then
        pcall(session.client.close, session.client)
    end

    session.client = nil

    if session.server and session.server.close then
        pcall(session.server.close, session.server)
    end

    session.server = nil
end

---@return moonbug.ThreadHandle
local function current_handle()
    local co, is_main = coroutine.running()
    if is_main or co == nil then
        return main_thread
    end

    return co
end

---@param handle? moonbug.ThreadHandle
---@return moonbug.ThreadContext
local function get_context(handle)
    handle = handle or current_handle()

    local ctx = session.context[handle]

    if not ctx then
        ctx = {
            id = next_thread_id,
            name = string.format("coroutine #%d", next_thread_id - 1),
            base_depth = nil,
            stack_level = 0,
            frames = {},
        }

        next_thread_id = next_thread_id + 1
        session.context[handle] = ctx
    end

    return ctx
end

local function purge_dead_threads()
    local dead = {}

    for handle in pairs(session.context) do
        if
            handle ~= main_thread
            ---@cast handle thread
            and coroutine.status(handle) == "dead"
        then
            table.insert(dead, handle)
        end
    end

    for _, handle in ipairs(dead) do
        session.context[handle] = nil
    end
end

---@param thread_id number
---@return moonbug.ThreadHandle?
local function get_thread_handle_from_id(thread_id)
    if thread_id == main_thread_id then
        return main_thread
    end

    for handle, ctx in pairs(session.context) do
        if ctx.id == thread_id then
            return handle
        end
    end

    return nil
end

---@param frame_id integer
---@return moonbug.ThreadHandle? handle
---@return integer?              depth
local function find_frame(frame_id)
    for handle, ctx in pairs(session.context) do
        local depth = ctx.frames[frame_id]

        if depth then
            return handle, depth
        end
    end

    return nil, nil
end

---Resolves the `ordinal`-th user frame of handle
---@param handle  moonbug.ThreadHandle
---@param ordinal integer
---@param kind    "info"|"local"
---@param format? string  for kind == "info"
---@param index?  integer for kind == "local"
---@return boolean ok
---@return ...     debuginfo? or name?, value?
local function frame_access(handle, ordinal, kind, format, index)
    local is_foreign_handle = handle ~= current_handle()
    local level = is_foreign_handle and 1 or 2
    local seen = 0

    while true do
        local info
        if is_foreign_handle then
            ---@cast handle thread
            info = debug.getinfo(handle, level, "S")
        else
            info = debug.getinfo(level, "S")
        end

        if not info then
            return false
        end

        if is_user_frame(info) then
            seen = seen + 1

            if seen == ordinal then
                if kind == "local" then
                    assert(index ~= nil, "index must be set for kind == 'local'")

                    if is_foreign_handle then
                        ---@cast handle thread
                        return true, debug.getlocal(handle, level, index)
                    end

                    return true, debug.getlocal(level, index)
                end

                assert(format ~= nil, "format must be set for kind == 'info'")

                if is_foreign_handle then
                    ---@cast handle thread
                    return true, debug.getinfo(handle, level, format)
                end

                return true, debug.getinfo(level, format)
            end
        end

        level = level + 1
    end
end

---@param handle  moonbug.ThreadHandle
---@param ordinal integer
---@param format  string
---@return debuginfo?
local function frame_getinfo(handle, ordinal, format)
    local ok, info = frame_access(handle, ordinal, "info", format)
    return ok and info or nil
end

---@param handle  moonbug.ThreadHandle
---@param ordinal integer
---@param index   integer
---@return string?
---@return any?
local function frame_getlocal(handle, ordinal, index)
    local ok, name, value = frame_access(handle, ordinal, "local", nil, index)
    if not ok then
        return nil
    end
    return name, value
end

---@param object moonbug.dap.ProtocolMessage
local function session_send_seq(object)
    session.seq = session.seq + 1
    object.seq = session.seq
    send_message(session.client, object)
end

---@param event moonbug.DapEvent
---@param body? any
local function session_send_event(event, body)
    session_send_seq {
        seq = -1, -- will be filled out by send_seq
        type = "event",
        event = event,
        body = body or {},
    }
end

---Send a dap output event
---@param category "console"|"important"|"stdout"|"stderr"|"telemetry"|string
---@param output   string
---@param source?  moonbug.dap.Source
---@param line?    integer
---@return boolean
local function session_send_output(category, output, source, line)
    if not session.ready or not session.client then
        return false
    end

    session_send_event("output", {
        category = category,
        output = output,
        source = source,
        line = line,
    })
    return true
end

---@param req     moonbug.dap.Request
---@param ok      boolean
---@param body    any
---@param message any
local function session_send_response(req, ok, body, message)
    session_send_seq {
        seq = -1, -- will be filled out by send_seq
        type = "response",
        request_seq = req.seq,
        success = ok,
        command = req.command,
        body = body,
        message = message,
    }
end

---Sends an error message back to the client
---@param req     moonbug.dap.Request
---@param message string
local function session_send_error(req, message)
    log.error(message)
    session_send_response(req, false, { error = { id = 1, format = message } }, message)
end

---@param req moonbug.dap.Request
---@return boolean
local function session_requires_pause(req)
    if session.paused and session.ready then
        return true
    end

    session_send_response(req, false, nil, "notStopped")
    return false
end

---@param handle moonbug.ThreadHandle
---@param depth  integer
---@return integer
local function count_locals(handle, depth)
    local n = 0
    local i = 1

    while true do
        local name = frame_getlocal(handle, depth, i)
        if not name then
            break
        end

        if not is_pseudo_variable(name) then
            n = n + 1
        end

        i = i + 1
    end

    return n
end

---@param fn function
---@return integer
local function count_upvalues(fn)
    local n = 0
    local i = 1

    while true do
        local name = debug.getupvalue(fn, i)
        if not name then
            break
        end

        if not hidden_keys[name] then
            n = n + 1
        end

        i = i + 1
    end

    return n
end

---@return string[]
local function global_keys()
    local keys = {}

    for k in pairs(_G) do
        if not hidden_keys[k] then
            table.insert(keys, k)
        end
    end

    table.sort(keys, function(a, b)
        return safe_tostring(a) < safe_tostring(b)
    end)

    return keys
end

---@param kind moonbug.VariableKind
---@param data table
---@return integer
local function variable_ref(kind, data)
    local id = session.variables.next_id
    session.variables.next_id = id + 1
    session.variables.refs[id] = { kind = kind, data = data }
    return id
end

---Serializes a Lua value into a DAP value
---@param v     any
---@param name  string
---@return moonbug.dap.Variable
local function serialize_value(v, name)
    local variable = {
        name = name,
        type = type(v),
        value = safe_tostring(v),
        variablesReference = 0,
    }

    if type(v) == "table" then
        local length = table_array_length(v)

        variable.variablesReference = variable_ref("table", { tbl = v })
        variable.indexedVariables = length
        variable.namedVariables = table_named_count(v, length)
    end

    return variable
end

---@return moonbug.dap.Variable[]
local function global_variables()
    local keys = global_keys()
    local vars = {}

    for _, k in ipairs(keys) do
        table.insert(vars, serialize_value(_G[k], M.compat.tostring(k)))
    end

    return vars
end

---@param tbl          table
---@param filter?      "indexed"|"named"
---@param start_index? integer
---@param count?       integer
---@return moonbug.dap.Variable[]
local function table_variables(tbl, filter, start_index, count)
    local length = table_array_length(tbl)
    start_index = start_index or 0

    local vars = {}

    if filter == "indexed" then
        local total = length
        local hi = (count and count ~= 0) and math.min(start_index + count, total) or math.min(total, table_max_items)

        for i = start_index + 1, hi do
            table.insert(vars, serialize_value(rawget(tbl, i), string.format("[%d]", i)))
        end

        return vars
    end

    local keys = table_named_keys(tbl, length)

    if filter == "named" then
        local total = #keys
        local hi = (count and count ~= 0) and math.min(start_index + count, total) or math.min(total, table_max_items)

        for i = start_index + 1, hi do
            table.insert(vars, serialize_value(rawget(tbl, keys[i]), M.compat.tostring(keys[i])))
        end

        return vars
    end

    -- no filter means both partitions
    local total = length + #keys
    local hi = (count and count ~= 0) and math.min(start_index + count, total) or math.min(total, table_max_items)
    for i = start_index + 1, hi do
        if i <= length then
            table.insert(vars, serialize_value(rawget(tbl, i), string.format("[%d]", i)))
        else
            local k = keys[i - length]
            table.insert(vars, serialize_value(rawget(tbl, k), M.compat.tostring(k)))
        end
    end

    return vars
end

---Get the currently set eval timeout
---@return number
local function eval_timeout()
    return (session.config and session.config.eval_timeout) or eval_default_timeout
end

---@param body    function
---@param timeout number
---@return table
local function run_with_timeout(body, timeout)
    local deadline = M.compat.socket_gettime() + timeout

    local check_timeout = function()
        if M.compat.socket_gettime() > deadline then
            error(string.format("moonbug: evaluation timed out after %ss", timeout), 0)
        end
    end

    local hook, mask, count = debug.gethook()
    debug.sethook(check_timeout, "", eval_count_budget)

    local results = M.compat.pack(pcall(body))

    if hook then
        if count and count > 0 then
            debug.sethook(hook, mask, count)
        else
            debug.sethook(hook, mask)
        end
    else
        debug.sethook()
    end

    return results
end

---@param ordinal    integer
---@param src      string
---@param timeout? number
---@param context? "repl"|"watch"|"hover"|"clipboard"|"variables"
---@return boolean                    ok
---@return table<integer, any>|string error message when ok = false
---@return integer                    count
local function evaluate_expr(ordinal, src, timeout, context)
    context = context or "repl"

    local level = 2 -- 1 = this function
    local seen = 0

    while true do
        local info = debug.getinfo(level, "S")
        if not info then
            return false, "stack frame is no longer valid", 0
        end

        if is_user_frame(info) then
            seen = seen + 1

            if seen == ordinal then
                break
            end
        end

        level = level + 1
    end

    -- only repl context allows mutations
    local is_mutable = context == "repl"

    ---@type function|nil
    local fn

    ---@type string|nil
    local err

    if is_mutable then
        fn, err = M.compat.loadstring(src, "=(moonbug eval)")
    end

    if not fn then
        fn, err = M.compat.loadstring(string.format("return %s", src), "=(moonbug eval)")
    end

    if not fn then
        return false, err or "syntax error", 0
    end

    -- create a snapshot of the frames locals/upvalues
    local env = {}
    local func = debug.getinfo(level, "f").func
    local i = 1

    while true do
        local name, value = debug.getupvalue(func, i)

        if not name then
            break
        end

        if not is_pseudo_variable(name) then
            env[name] = value
        end

        i = i + 1
    end

    i = 1

    while true do
        local name, value = debug.getlocal(level, i)

        if not name then
            break
        end

        if not is_pseudo_variable(name) then
            env[name] = value
        end

        i = i + 1
    end

    local varargs = {}
    i = 1

    while true do
        local name, value = debug.getlocal(level, -i)
        if not name then
            break
        end

        varargs[i] = value
        i = i + 1
    end

    if is_mutable then
        setmetatable(env, { __index = _G, __newindex = _G })
    else
        setmetatable(env, {
            __index = _G,
            __newindex = function(_, key)
                error(string.format("cannot assign to '%s' in a read-only context", M.compat.tostring(key)), 2)
            end,
        })
    end

    M.compat.setfenv(fn, env)

    timeout = timeout or eval_timeout()

    local results = run_with_timeout(function()
        return fn(M.compat.unpack(varargs))
    end, timeout)

    -- write back results if mutable
    if is_mutable then
        local n = 0
        while debug.getlocal(level, n + 1) do
            n = n + 1
        end

        local done = {}

        for j = n, 1, -1 do
            local nm = debug.getlocal(level, j)
            if nm and not is_pseudo_variable(nm) and not done[nm] then
                done[nm] = true
                debug.setlocal(level, j, env[nm])
            end
        end

        local j = 1

        while true do
            local nm = debug.getupvalue(func, j)
            if not nm then
                break
            end

            if not is_pseudo_variable(nm) and not done[nm] then
                done[nm] = true
                debug.setupvalue(func, j, env[nm])
            end

            j = j + 1
        end
    end

    if not results[1] then
        return false, M.compat.tostring(results[2]), 0
    end

    local count = results.n - 1
    local values = {}

    for k = 2, results.n do
        values[k - 1] = results[k]
    end

    if count == 0 then
        values = { nil }
        count = 1
    end

    return true, values, count
end

---@param v     table<integer, any>
---@param count integer
---@return table
local function serialize_eval_result(v, count)
    if count ~= 1 then
        local parts = {}

        for i = 1, count do
            parts[i] = M.compat.tostring(v[i])
        end

        return {
            result = table.concat(parts, "\t"),
            variablesReference = 0,
        }
    end

    local s = serialize_value(v[1], "result")
    return {
        result = s.value,
        type = s.type,
        variablesReference = s.variablesReference,
        indexedVariables = s.indexedVariables,
        namedVariables = s.namedVariables,
    }
end

---Formats the current call stack as text
---@return string
local function capture_stacktrace()
    local parts = { "stack traceback:" }
    local depth = 1

    while true do
        local info = debug.getinfo(depth, "Snl")
        if not info then
            break
        end

        if is_user_frame(info) then
            local label = info.what == "main" and "main chunk"
                or string.format("function '%s'", info.name or "(anonymous)")
            table.insert(parts, string.format("\t%s:%d: in %s", info.short_src, info.currentline, label))
        end

        depth = depth + 1
    end

    return table.concat(parts, "\n")
end

---@return integer
local function get_port()
    return tonumber(M.compat.getenv "MOONBUG_PORT") or default_port
end

---@param host string?
---@param port integer?
---@return moonbug.Socket?
---@return string?
local function bind(host, port)
    local h = host or "127.0.0.1"
    local p = port or get_port()

    local server, err = M.compat.socket_bind(h, p)
    if not server then
        log.error("could not bind '%s:%d': %s", h, p, err)
        return nil, err
    end

    log.debug("successfully bound socket to '%s:%d'", h, p)

    server:settimeout(0)
    return server, nil
end

---@param req moonbug.dap.Request
local function dispatch(req)
    log.debug("dispatch command: %s", req.command)

    local curr_handle = current_handle()
    local curr_ctx = get_context(curr_handle)

    if req.command == dap_cmds.initialize then
        ---@type moonbug.dap.InitializeRequestArguments
        local args = req.arguments or {}
        session.client_args = args

        -- sort client args/caps by key and print them
        local keys = {}

        for key in pairs(args) do
            table.insert(keys, key)
        end

        table.sort(keys)

        for _, k in ipairs(keys) do
            local v = args[k]

            if v then
                log.debug("client:%s: %s", k, M.compat.tostring(v))
            end
        end

        session_send_response(req, true, server_capabilities)
        session_send_event(dap_events.initialized)
        return
    elseif req.command == dap_cmds.set_exception_breakpoints then
        local on = {}
        for _, f in ipairs(req.arguments.filters or {}) do
            on[f] = true
        end

        session.filters.error = on.error or false
        session.filters.pcall = on.pcall or false
        session.filters.uncaught = on.uncaught or false
        session_send_response(req, true, {})
        return
    elseif req.command == dap_cmds.set_breakpoints then
        local args = req.arguments or {}
        local path = path_resolve(args.source and args.source.path, session.project_root_dir)
        local list = {}

        session.breakpoints[path] = {}

        for _, bp in ipairs(args.breakpoints or {}) do
            local line = bp.line
            local ok = path ~= "" and line ~= nil

            if ok then
                local condition = ""

                if bp.condition then
                    condition = condition .. " cond: " .. bp.condition
                end

                if bp.hitCondition then
                    condition = condition .. " hit_cond: " .. bp.hitCondition
                end

                log.debug("    set breakpoint: %s:%d%s", path, line, condition)

                session.breakpoints[path][line] = {
                    condition = bp.condition,
                    hit_condition = bp.hitCondition,
                    log_message = bp.logMessage,
                    hit_count = 0,
                }
            end

            table.insert(list, { line = line, verified = ok })
        end

        session_send_response(req, true, { breakpoints = M.compat.json_empty(list) })
        return
    elseif req.command == dap_cmds.configuration_done then
        session_send_response(req, true, {})

        if session.config and session.config.stop_on_entry then
            session.step = "entry"
        end

        return
    elseif req.command == dap_cmds.threads then
        purge_dead_threads()

        ---@type { id: number, name: string }[]
        local threads = {}

        for h, c in pairs(session.context) do
            if
                h == main_thread
                ---@cast h thread if its not main_thread its guaranteed to be thread
                or coroutine.status(h) ~= "dead"
            then
                table.insert(threads, {
                    id = c.id,
                    name = c.name,
                })
            end
        end

        table.sort(threads, function(a, b)
            return a.id < b.id
        end)

        session_send_response(req, true, { threads = M.compat.json_empty(threads) })
        return
    elseif req.command == dap_cmds.stack_trace then
        local args = req.arguments or {}
        local target = get_thread_handle_from_id(args.threadId or main_thread_id)

        if not target then
            session_send_error(req, "invalid threadId")
            return
        end

        local frames = {}
        local target_ctx = get_context(target)

        ---@param info debuginfo
        ---@param frame_depth integer
        local function push_frame(info, frame_depth)
            local name = info.name or "(anonymous)"
            local line = info.currentline or 0
            local path = path_resolve(info.source, session.project_root_dir)

            table.insert(frames, {
                id = session.next_frame_id,
                name = name,
                line = line,
                column = 1,
                source = {
                    path = path,
                    name = (info.short_src or ""):match "[^/\\]+$" or info.short_src,
                },
            })

            target_ctx.frames[session.next_frame_id] = frame_depth
            session.next_frame_id = session.next_frame_id + 1
        end

        if target == main_thread and target ~= current_handle() then
            -- main requested while stopped inside coroutine: impossible!
            table.insert(frames, {
                id = session.next_frame_id,
                name = "unable to access main thread while in a coroutine",
                line = 0,
                column = 1,
            })

            session.next_frame_id = session.next_frame_id + 1
        else
            -- walk user frames of the thread (current or suspended)
            local is_foreign_handle = target ~= current_handle()
            local depth = is_foreign_handle and 1 or 2
            local ordinal = 0

            while true do
                local info = nil

                if is_foreign_handle then
                    ---@cast target thread
                    info = debug.getinfo(target, depth, "Snl")
                else
                    info = debug.getinfo(depth, "Snl")
                end

                if not info then
                    break
                end

                if is_user_frame(info) then
                    ordinal = ordinal + 1
                    push_frame(info, ordinal)
                end

                depth = depth + 1
            end
        end

        session_send_response(req, true, {
            stackFrames = M.compat.json_empty(frames),
            totalFrames = #frames,
        })
        return
    elseif req.command == dap_cmds.continue_ then
        if not session_requires_pause(req) then
            return
        end

        curr_ctx.frames = {}
        session.variables.refs = {}
        session.paused = false
        session.step = nil
        curr_ctx.exception = nil

        session_send_response(req, true, { allThreadsContinued = true })
        session_send_event(dap_events.continued, { threadId = curr_ctx.id, allThreadsContinued = true })
        return
    elseif req.command == dap_cmds.pause then
        session.step = "pause"
        session_send_response(req, true, {})
        return
    elseif req.command == dap_cmds.next_ then
        if not session_requires_pause(req) then
            return
        end

        session.step = "over"
        session.step_level = curr_ctx.stack_level
        session.step_thread = curr_handle
        session.paused = false
        curr_ctx.exception = nil

        session_send_response(req, true, {})
        return
    elseif req.command == dap_cmds.step_in then
        if not session_requires_pause(req) then
            return
        end

        session.step = "in"
        session.paused = false
        curr_ctx.exception = nil
        session_send_response(req, true, {})
        return
    elseif req.command == dap_cmds.step_out then
        if not session_requires_pause(req) then
            return
        end

        session.step = "out"
        session.step_level = curr_ctx.stack_level - 1
        session.step_thread = curr_handle
        session.paused = false
        curr_ctx.exception = nil

        session_send_response(req, true, {})
        return
    elseif req.command == dap_cmds.scopes then
        if not session_requires_pause(req) then
            return
        end

        local frame_handle, depth = find_frame(req.arguments.frameId)
        if not frame_handle or not depth then
            session_send_error(req, "invalid frameId")
            return
        end

        ---@type moonbug.dap.Scope[]
        local scopes = {
            {
                name = "Local",
                variablesReference = variable_ref("locals", { handle = frame_handle, depth = depth }),
                presentationHint = "locals",
                namedVariables = count_locals(frame_handle, depth),
                expensive = false,
            },
        }

        local info = frame_getinfo(frame_handle, depth, "Sf")

        if info and info.what == "Lua" then
            table.insert(scopes, {
                name = "Upvalue",
                variablesReference = variable_ref("upvalues", { func = info.func }),
                namedVariables = count_upvalues(info.func),
                expensive = false,
            })
        end

        table.insert(scopes, {
            name = "Global",
            variablesReference = variable_ref("globals", {}),
            namedVariables = #global_keys(),
            expensive = false,
        })

        session_send_response(req, true, { scopes = scopes })
        return
    elseif req.command == dap_cmds.variables then
        if not session_requires_pause(req) then
            return
        end

        local args = req.arguments or {}
        local supports_paging = session.client_args and session.client_args.supportsVariablePaging == true

        local ref = session.variables.refs[args.variablesReference]
        if not ref then
            session_send_error(req, "invalid variablesReference")
            return
        end

        local variables = {}

        if ref.kind == "locals" then
            assert(ref.data.handle, "locals must have `handle` value")
            assert(ref.data.depth, "locals must have `depth` value")

            if not frame_getinfo(ref.data.handle, ref.data.depth, "S") then
                session_send_error(req, "stack frame is no longer valid")
                return
            end

            local i = 1
            local name, value = frame_getlocal(ref.data.handle, ref.data.depth, 1)

            while name do
                if not is_pseudo_variable(name) then
                    table.insert(variables, serialize_value(value, name))
                end

                i = i + 1
                name, value = frame_getlocal(ref.data.handle, ref.data.depth, i)
            end
        elseif ref.kind == "upvalues" then
            assert(ref.data.func, "upvalues must have `func` value")

            local i = 1
            local name, value = debug.getupvalue(ref.data.func, i)

            while name do
                if not hidden_keys[name] then
                    table.insert(variables, serialize_value(value, name))
                end

                i = i + 1
                name, value = debug.getupvalue(ref.data.func, i)
            end
        elseif ref.kind == "globals" then
            variables = global_variables()
        elseif ref.kind == "table" then
            assert(ref.data.tbl, "tables must have `tbl` value")

            if supports_paging then
                variables = table_variables(ref.data.tbl, args.filter, args.start, args.count)
            else
                variables = table_variables(ref.data.tbl, args.filter)
            end
        end

        if
            -- if the client supports paging just show how much they ask for
            supports_paging
            -- tables are already paged
            and ref.kind ~= "table"
        then
            variables = slice(variables, args.start, args.count)
        end

        session_send_response(req, true, { variables = M.compat.json_empty(variables) })
        return
    elseif req.command == dap_cmds.evaluate then
        if not session_requires_pause(req) then
            return
        end

        local args = req.arguments or {}
        local frame_handle, depth = find_frame(args.frameId)
        if not frame_handle or not depth then
            session_send_error(req, "invalid frameId")
            return
        end

        if frame_handle ~= current_handle() then
            session_send_error(req, "cannot evaluate in a suspended thread")
            return
        end

        local ok, res, count = evaluate_expr(depth, args.expression, nil, args.context)
        if not ok then
            ---@cast res string
            session_send_error(req, res or "unknown error")
            return
        end

        local timeout = eval_timeout()

        ---@cast res table<integer, any>
        local result = run_with_timeout(function()
            -- run inside timeout to guard from busy loading metamethods
            return serialize_eval_result(res, count)
        end, timeout)

        if not result[1] then
            session_send_error(req, M.compat.tostring(result[2]) or "failed to serialize evaluation result")
            return
        end

        session_send_response(req, true, result[2])
        return
    elseif req.command == dap_cmds.exception_info then
        if not session_requires_pause(req) then
            return
        end

        if not req.arguments.threadId then
            session_send_error(req, "invalid threadId")
            return
        end

        local requested_handle = get_thread_handle_from_id(req.arguments.threadId)
        if not requested_handle then
            session_send_error(req, "invalid threadId")
            return
        end

        local exception = session.context[requested_handle].exception
        if not exception then
            session_send_error(req, "no exception information available or invalid threadId")
            return
        end

        session_send_response(req, true, {
            exceptionId = "error",
            description = exception.message,
            breakMode = exception.caught and "always" or "unhandled",
            details = {
                message = exception.message,
                stackTrace = capture_stacktrace(),
            },
        })
        return
    elseif req.command == dap_cmds.launch or req.command == dap_cmds.attach then
        local args = req.arguments or {}

        if not session.project_root_dir then
            session.project_root_dir = args.project_root_dir or args.cwd or args["workspaceFolder"]
        end

        session_send_response(req, true, {})
        return
    elseif req.command == dap_cmds.disconnect or req.command == dap_cmds.terminate then
        curr_ctx.frames = {}
        session.variables.refs = {}
        session.ready = false
        session.paused = false
        session.step = nil

        session_send_response(req, true, {})

        if req.command == dap_cmds.terminate then
            session_send_event(dap_events.terminated)
            session.terminate_requested = true
        else
            remove_debug_hook()
            uninstall_wrappers()
        end

        if session.client then
            pcall(function()
                session.client:close()
            end)
        end

        return
    end

    session_send_error(req, string.format("unsupported command found: %s", M.compat.tostring(req.command)))
end

---@param sock moonbug.Socket
---@param timeout number?
---@return boolean
---@return string?
local function handshake(sock, timeout)
    session.client = sock
    sock:settimeout(timeout or 5)

    while true do
        local req, req_err = read_message(sock)
        if req_err ~= nil then
            return false, req_err
        end

        if type(req) ~= "table" or req.type ~= "request" then
            return false, "bad dap request"
        end

        ---@cast req moonbug.dap.Request
        local dispatch_ok, dispatch_err = pcall(dispatch, req)
        if not dispatch_ok then
            log.error("dispatch(%s) failed: %s", M.compat.tostring(req.command), M.compat.tostring(dispatch_err))
        end

        if req.command == dap_cmds.configuration_done then
            session.ready = true
            return true, nil
        end

        if req.command == dap_cmds.disconnect or req.command == dap_cmds.terminate then
            session.ready = false
            return false, "disconnected during handshake"
        end
    end
end

local function debug_loop()
    if not session.client then
        session.paused = false
        return
    end

    session.client:settimeout(0.5)

    while session.paused and session.ready and session.client ~= nil do
        local req, err = read_message(session.client)
        if not req then
            if err == "timeout" then
                -- still paused, wait longer
            elseif err == "closed" then
                session.ready = false
                session.paused = false
                session.client = nil
            else
                log.error("debug loop: %s", err)
            end
        elseif req.type == "request" then
            ---@cast req moonbug.dap.Request
            local dispatch_ok, dispatch_err = pcall(dispatch, req)
            if not dispatch_ok then
                log.error(
                    "debug_loop dispatch(%s) failed: %s",
                    M.compat.tostring(req.command),
                    M.compat.tostring(dispatch_err)
                )
                session_send_error(req, M.compat.tostring(dispatch_err))
            end
        end
    end
end

---@param reason       string
---@param description? string
local function stop(reason, description)
    local ctx = get_context()

    purge_dead_threads()

    session.paused = true
    session.step = nil
    session.step_thread = nil

    for _, c in pairs(session.context) do
        c.frames = {}
    end

    session.next_frame_id = 1

    if reason ~= "exception" then
        ctx.exception = nil
    end

    log.debug("stop: %s%s", reason, (description and string.format(" (%s)", description)) or "")

    session_send_event(dap_events.stopped, {
        reason = reason,
        description = description,
        threadId = ctx.id,
        allThreadsStopped = true,
    })
    debug_loop()
end

---@return boolean
local function error_is_caught()
    local i = 2

    while true do
        local info = debug.getinfo(i, "Sf")
        if not info then
            return false
        end

        if info.func == pcall or info.func == xpcall then
            return true
        end

        i = i + 1
    end
end

---@param message string
local function maybe_pause_on_error(message)
    if not session.ready or not session.client or session.paused or not session.filters.error then
        return
    end

    local caught = error_is_caught()

    local co, is_main = coroutine.running()
    if co ~= nil and not is_main and not caught then
        -- let error escape this coroutine, let coroutine.resume handle it
        return
    end

    if (caught and session.filters.pcall) or (not caught and session.filters.uncaught) then
        local ok, text = pcall(M.compat.tostring, message)

        local ctx = get_context()
        ctx.exception = {
            message = ok and text or "unknown error",
            caught = caught,
        }

        stop("exception", ok and text or nil)
    end
end

---@param message any
---@param level?  integer
local function wrapped_error(message, level)
    maybe_pause_on_error(message)

    if level == 0 then
        error(message, 0)
        return
    end

    error(message, (level or 1) + 1)
end

---@param value any
---@param ...   any
---@return any
---@return any
local function wrapped_assert(value, ...)
    if value then
        return value, ...
    end

    local message = select(1, ...) or "assertion failed!"
    maybe_pause_on_error(message)
    error(message, 2)
end

local function install_wrappers()
    rawset(_G, "error", wrapped_error)
    rawset(_G, "assert", wrapped_assert)
    rawset(_G, "print", function(...)
        if session.config and session.config.forward_output == false then
            print(...)
            return
        end

        local args = M.compat.pack(...)
        local parts = {}

        for i = 1, args.n do
            table.insert(parts, M.compat.tostring(args[i]))
        end

        local line = table.concat(parts, "\t") .. "\n"

        -- still print normally
        print(...)

        -- but also send the print command to the client
        session_send_output("stdout", line)
    end)
    rawset(_G.coroutine, "create", function(f)
        local thread = coroutine_create(f)
        local ctx = get_context(thread)

        if not jit then
            debug.sethook(thread, debug_hook, "l")
        end

        log.debug("coroutine #%d created", ctx.id)

        return thread
    end)
    rawset(_G.coroutine, "wrap", function(f)
        return coroutine_wrap(function(...)
            local thread = coroutine.running()
            local ctx = get_context(thread)

            if not jit then
                debug.sethook(thread, debug_hook, "l")
            end

            log.debug("coroutine #%d wrapped", ctx.id)

            return f(...)
        end)
    end)
    rawset(_G.coroutine, "resume", function(thread, ...)
        local results = M.compat.pack(coroutine_resume(thread, ...))

        if not results[1] and session.ready and not session.paused and session.filters.error then
            local caught = error_is_caught()

            if (caught and session.filters.pcall) or (not caught and session.filters.uncaught) then
                local ctx = get_context()

                ctx.exception = {
                    message = M.compat.tostring(results[2]),
                    caught = caught,
                }

                stop "exception"
            end
        end

        return M.compat.unpack(results, 1, results.n)
    end)
end

uninstall_wrappers = function()
    rawset(_G, "error", error)
    rawset(_G, "assert", assert)
    rawset(_G, "print", print)
    rawset(_G.coroutine, "create", coroutine_create)
    rawset(_G.coroutine, "wrap", coroutine_wrap)
    rawset(_G.coroutine, "resume", coroutine_resume)
end

---@param hit_condition string
---@param hit_count     integer
---@return boolean
local function hit_condition_met(hit_condition, hit_count)
    local op, num = hit_condition:match "^%s*([<>=~!%%]?=?)%s*(%d+)%s*$"
    num = num and tonumber(num)

    if not num then
        log.error("invalid hit condition: %s", M.compat.tostring(hit_condition))
        return false
    end

    if op == ">" then
        return hit_count > num
    elseif op == ">=" then
        return hit_count >= num
    elseif op == "<" then
        return hit_count < num
    elseif op == "<=" then
        return hit_count <= num
    elseif op == "=" or op == "==" then
        return hit_count == num
    elseif op == "~=" or op == "!=" then
        return hit_count ~= num
    elseif op == "%" and num > 0 then
        return hit_count % num == 0
    end

    return hit_count == num
end

---Has breakpoint been hit?
---@param source string
---@param line   integer
---@return boolean
local function hit_breakpoint(source, line)
    local canonical_path = path_resolve(source, session.project_root_dir)
    local bp = session.breakpoints[canonical_path] and session.breakpoints[canonical_path][line]
    if not bp then
        return false
    end

    if bp.condition then
        local timeout = eval_timeout()

        --- read only context so conditions cant mutate locals/upvalues
        --- ordinal 1 = the function executing the breakpoint; debugger internal
        --- frames (debug_hook, hit_breakpoint) are skipped automatically
        local ok, res = evaluate_expr(1, bp.condition, timeout, "watch")

        if ok and not res[1] then
            -- condition evaluated to nil/false
            return false
        end

        if not ok then
            -- treat eval errors as a hit
            log.error("breakpoint condition error: %s", M.compat.tostring(res))
        end
    end

    bp.hit_count = bp.hit_count + 1

    if bp.hit_condition and not hit_condition_met(bp.hit_condition, bp.hit_count) then
        return false
    end

    if bp.log_message then
        local timeout = eval_timeout()
        local values = {}

        for expr in bp.log_message:gmatch "{([^{}]*)}" do
            if values[expr] == nil then
                local ok, res = evaluate_expr(1, expr, timeout, "watch")
                if not ok then
                    log.error("log point expression error: %s", M.compat.tostring(res))
                    values[expr] = string.format("<error: %s>", M.compat.tostring(res))
                else
                    values[expr] = safe_tostring(res[1])
                end
            end
        end

        session_send_output("console", bp.log_message:gsub("{([^{}]*)}", values) .. "\n")
        return false
    end

    -- normal breakpoint hit
    return true
end

local function poll_accept()
    if session.ready or not session.server then
        return
    end

    local client = session.server:accept()
    if not client then
        return
    end

    client:setoption("tcp-nodelay", true)

    local ok, handshake_err = handshake(client, 5)
    if not ok then
        log.debug("handshake failed: %s", M.compat.tostring(handshake_err))
        pcall(client.close, client)
        session.client = nil
        return
    end

    if session.config.stop_on_attach then
        session.step = "pause"
    end
end

local function poll_running()
    if not session.ready or session.paused or session.client == nil then
        return
    end

    session.client:settimeout(0)

    local req, err = read_message(session.client)
    if req == nil and err == "closed" then
        session.ready = false
        session.paused = false
        session.client = nil
        return
    end

    if type(req) == "table" and req.type == "request" then
        ---@cast req moonbug.dap.Request
        dispatch(req)
    end
end

local function absolute_depth()
    local n = 0
    local level = 2

    while true do
        local info = debug.getinfo(level, "S")

        if not info then
            break
        end

        if info.what == "Lua" then
            n = n + 1
        end

        level = level + 1
    end

    return n
end

debug_hook = function(event, line)
    if session.terminate_requested then
        error("moonbug: debuggee terminated", 0)
    end

    if event ~= "line" then
        return
    end

    local info = debug.getinfo(2, "S")
    if not info or info.source == self_src then
        return
    end

    if session.paused then
        return
    end

    if not session.ready then
        poll_accept()
        return
    end

    poll_running()

    local handle = current_handle()
    local ctx = get_context(handle)

    if not ctx.base_depth then
        ctx.base_depth = absolute_depth()
    end

    ctx.stack_level = absolute_depth() - ctx.base_depth

    local reason = nil

    if session.step == "pause" then
        reason = "pause"
    elseif session.step == "entry" then
        reason = "entry"
    elseif session.step == "in" then
        reason = "step"
    elseif session.step == "over" and handle == session.step_thread and ctx.stack_level <= session.step_level then
        reason = "step"
    elseif session.step == "out" and handle == session.step_thread and ctx.stack_level <= session.step_level then
        reason = "step"
    elseif hit_breakpoint(info.source, line) then
        reason = "breakpoint"
    end

    if reason then
        stop(reason)
    end
end

local saved_hook, saved_mask, saved_count

local function setup_debug_hook()
    local hook, mask, count = debug.gethook()
    if hook ~= debug_hook then
        saved_hook = hook
        saved_mask = mask
        saved_count = count
    end

    local handle = current_handle()
    local ctx = get_context(handle)

    ctx.base_depth = absolute_depth()
    ctx.stack_level = 0

    debug.sethook(debug_hook, "l")
end

remove_debug_hook = function()
    if debug.gethook() == debug_hook then
        debug.sethook(saved_hook, saved_mask, saved_count)
    end

    saved_hook = nil
    saved_mask = nil
    saved_count = nil

    -- NOTE(luajit): luajit installs hooks on all threads, for others we have to do it one by one
    if not jit then
        for handle in pairs(session.context) do
            if handle ~= main_thread then
                debug.sethook(handle)
            end
        end
    end
end

---@param host? string
---@param port? integer
---@param opts? moonbug.Config
---@return boolean
---@return string?
function M.listen(host, port, opts)
    log.info("Hello Moonbug v%s!", M.version)
    log.debug("attempt to listen on '%s:%d'", host, port)

    -- reset session back to zero state
    session_reset()

    session.config = opts or {}

    install_wrappers()

    local server, err = bind(host, port)
    if err ~= nil then
        return false, "could not create server"
    end
    assert(server)

    session.server = server

    if session.config.wait == true then
        local deadline = session.config.max_wait_time and (M.compat.socket_gettime() + session.config.max_wait_time)
        session.server:settimeout(0.1)

        while true do
            local client = session.server:accept()
            if client then
                log.debug "accepted client"
                client:setoption("tcp-nodelay", true)
                session.server:settimeout(0)

                local ok, handshake_err = handshake(client, 30)
                if ok then
                    setup_debug_hook()
                    return true, nil
                end

                log.debug("handshake failed: %s. Waiting for another client...", handshake_err)
                pcall(client.close, client)
                session.server:settimeout(0.1)
            end

            if deadline and M.compat.socket_gettime() > deadline then
                log.error "wait timeout exceeded"

                session.server:settimeout(0)
                setup_debug_hook()

                return false, "wait timeout exceeded"
            end
        end
    end

    setup_debug_hook()
    session.server:settimeout(0)

    return true, nil
end

-- if test flag is set expose some functionality for testing purposes
if M.compat.getenv "MOONBUG_TEST" then
    local function reset()
        session_reset()
        remove_debug_hook()
        uninstall_wrappers()
    end

    ---@param handle moonbug.ThreadHandle
    ---@return integer
    local function get_stack_level(handle)
        handle = handle or current_handle()
        local ctx = get_context(handle)

        return ctx.stack_level
    end

    local function get_main_context()
        return get_context(main_thread)
    end

    local function get_main_thread()
        return main_thread
    end

    M._internal = {
        -- dap protocol
        parse_content_length = parse_content_length,
        read_message = read_message,
        send_message = send_message,

        -- pathlib
        path_is_absolute = path_is_absolute,
        path_join = path_join,
        path_normalize = path_normalize,
        path_resolve = path_resolve,

        -- helpers
        count_locals = count_locals,
        count_upvalues = count_upvalues,
        error_is_caught = error_is_caught,
        global_keys = global_keys,
        serialize_eval_result = serialize_eval_result,
        serialize_value = serialize_value,
        slice = slice,
        table_array_length = table_array_length,
        table_named_count = table_named_count,
        table_named_keys = table_named_keys,
        table_variables = table_variables,

        -- debugger
        debug_hook = debug_hook,
        dispatch = dispatch,
        evaluate_expr = evaluate_expr,
        get_context = get_context,
        get_main_context = get_main_context,
        get_main_thread = get_main_thread,
        get_stack_level = get_stack_level,
        handshake = handshake,
        hit_breakpoint = hit_breakpoint,
        hit_condition_met = hit_condition_met,
        remove_debug_hook = remove_debug_hook,
        setup_debug_hook = setup_debug_hook,

        reset = reset,
        session = session,
    }
end

return M
