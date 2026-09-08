---@class moonbug.test.Process
---@field pid integer
---@field pipe file*
---@field output_path string
local M = {}
M.__index = M

---@param value string
---@return string
local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param values string[]
---@return string
local function shell_join(values)
    local quoted = {}

    for i, value in ipairs(values) do
        quoted[i] = shell_quote(value)
    end

    return table.concat(quoted, " ")
end

---@param command string
---@return boolean
local function command_succeeded(command)
    local ok = os.execute(command)
    return ok == true or ok == 0
end

---@param path string
---@return string
local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return ""
    end

    local contents = file:read "*a"
    file:close()
    return contents
end

---@param lua       string
---@param launcher  string
---@param port      integer
---@param program   string
---@param coverage? boolean
---@param timeout?  integer
---@param env?      table
function M.start(lua, launcher, port, program, coverage, timeout, env)
    coverage = coverage or false
    timeout = timeout or 30
    env = env or {}

    local output_path = os.tmpname()

    local argv = {
        "timeout",
        "--signal=TERM",
        "--kill-after=2",
        tostring(timeout) .. "s",
    }

    table.insert(argv, "env")
    table.insert(argv, "-u")
    table.insert(argv, "MOONBUG_TEST") -- we want full blackbox tests so the internal functions shouldnt be available

    for k, v in pairs(env) do
        table.insert(argv, string.format("%s=%s", k, tostring(v)))
    end

    table.insert(argv, lua)

    if coverage then
        table.insert(argv, "-lluacov")
    end

    table.insert(argv, launcher)
    table.insert(argv, tostring(port))
    table.insert(argv, program)

    local script = string.format("printf '%%s\\n' \"$$\"; exec %s >%s 2>&1", shell_join(argv), shell_quote(output_path))

    local pipe = assert(io.popen("sh -c " .. shell_quote(script), "r"))
    local pid = assert(tonumber(pipe:read "*l"), "child did not report its pid")

    return setmetatable({
        pid = pid,
        pipe = pipe,
        output_path = output_path,
    }, M)
end

function M:output()
    return read_file(self.output_path)
end

function M:kill()
    command_succeeded("kill -TERM " .. tostring(self.pid) .. " 2>/dev/null")
end

function M:wait()
    self.pipe:close()
end

function M:close()
    self:wait()
    os.remove(self.output_path)
end

return M
