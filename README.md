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

## Integrations

### Neovim

Requires you have [mfussenegger/nvim-dap](https://github.com/mfussenegger/nvim-dap) setup.

```lua
local dap = require "dap"

dap.configurations.lua = {
    {
        type = "moonbug",
        request = "attach",
        name = "moonbug",
        project_root_dir = "${workspaceFolder}",
    },
}

dap.adapters.moonbug = {
    id = "moonbug",
    type = "server",
    port = os.getenv "MOONBUG_PORT" or 8888,
}
```

### Visual Studio Code

We have an official Visual Studio Code extension available here:

- Visual Studio Code Extension Store (coming soon...)
- [Github](https://github.com/atomicptr/vscode-moonbug)

### Defold

We have an official [Defold Game Engine](https://defold.com/) library available here: [atomicptr/defold-moonbug](http://github.com/atomicptr/defold-moonbug)

## Supported Lua Versions

- LuaJIT 2.x
- Lua 5.4
- Lua 5.5

## Dependencies

moonbug depends on [cjson](https://github.com/Davegamble/cjson) and [luasocket](https://github.com/lunarmodules/luasocket) for DAP related interactions, however this application has been written
in a way where you can overwrite the dependencies as long as you provide something else with the same shape.

First lets look at the compatibility table

```lua
---@class moonbug.compat.SocketLib
---@field bind    fun(host: string, port: integer): moonbug.Socket
---@field gettime fun(): integer

---@class moonbug.compat.JsonLib
---@field encode fun(v: any): string|nil
---@field decode fun(s: string): any
---@field empty  fun(tbl?: table): table

---@class moonbug.compat.Libs
---@field socket? moonbug.compat.SocketLib
---@field json?   moonbug.compat.JsonLib

---@class moonbug.Compat
---@field libs       moonbug.compat.Libs
---@field unpack     fun(list: table, i?: integer, j?: integer): ...
---@field pack       fun(...: any): { n: integer, [integer]: any }
---@field loadstring fun(text: string, chunkname?: string): (fun(): any)?|string
---@field log_fatal  fun(message: string)
---@field log_print  fun(message: string)
---@field getenv     fun(var: string): string|nil
---@field setfenv    fun(fn: function, env: table): function
---@field tostring   fun(v: any): string
```

Meaning that as long as you provide another function with the same signature here you can replace it, e.g.

```lua
local moonbug = require "moonbug"

local json = require "dkjson" -- using dkjson instead of cjson

moonbug.compat.libs.json = {
    encode = json.encode,
    decode = function(s)
        local res, _, err = json.decode(v)
        if err ~= nil then
            error(err)
        end

        return res
    end,
}

moonbug.listen(...)
```

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
