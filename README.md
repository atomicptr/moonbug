# moonbug

Single-file Lua debugger - in-process hooks, remote DAP, no extra binary.

Inspired by [pkulchenko/MobDebug](https://github.com/pkulchenko/MobDebug)

## Usage

Just import the moonbug module and get started!

```lua
local moonbug = require "moonbug" -- module path might vary

moonbug.listen(host, port, {
    wait = true, -- the process will block until a debugger attaches
})

-- Explore the `moonbug.Config` type for more options (or see below)
```

Thats it.

## Supported Lua Versions

- LuaJIT 2.x
- Lua 5.4
- Lua 5.5

## Dependencies

moonbug depends on [cjson]() and [luasocket]() for DAP related interactions, however this application has been written
in a way where you can overwrite the dependencies as long as you provide something else with the same shape.

First lets look at the compatibility table

```lua
---@class moondebug.Compat
---@field unpack         fun(list: table, i?: integer, j?: integer): ...
---@field pack           fun(...: any): { n: integer, [integer]: any }
---@field json_encode    fun(v: any): string|nil
---@field json_decode    fun(s: string): any
---@field json_empty     fun(tbl: table): table
---@field loadstring     fun(text: string, chunkname?: string): (fun(): any)?|string
---@field socket_bind    fun(host: string, port: integer): moonbug.Socket
---@field socket_gettime fun(): integer
---@field log_fatal      fun(message: string)
---@field log_print      fun(message: string)
---@field getenv         fun(var: string): string|nil
---@field setfenv        fun(fn: function, env: table): function
---@field tostring       fun(v: any): string
```

Meaning that as long as you provide another function with the same signature here you can replace it, e.g.

```lua
local moonbug = require "moonbug"

local json = require "dkjson" -- using dkjson instead of cjson

moonbug.compat.json_encode = function(v)
    return json.encode(v)
end

moonbug.compat.json_decode = function(s)
    local res, _, err = json.decode(v)
    if err ~= nil then
        error(err)
    end

    return res
end

moonbug.listen(...)
```

For `json` specifically, if you have a global `json` object that has an `encode` and `decode` function it'll just be
detected as is.

## Configuration

When starting the debugger there are a bunch of settings you can pick:

```lua
---@type moonbug.Config
local config = {
    ---@type boolean|nil
    wait = false, -- Block until debugger attaches

    ---@type integer|nil
    max_wait_time = nil, -- Maximum amount of time to wait for things to happen

    ---@type boolean|nil
    stop_on_entry = false, -- Stop the process when debugger configuration is done

    ---@type boolean|nil
    stop_on_attach = false, -- Stop the process when debugger attaches

    ---@type number|nil
    eval_timeout = 5, -- Seconds before `evaluate` is aborted (default: 5)

    ---@type boolean|nil
    forward_output = true, -- Forward print() to the debug console while attached (default: true)
}

require("moonbug").listen(host, port, config)
```

## License

MIT
