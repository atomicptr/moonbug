# moonbug

<img src="./.github/moonbug_logo.png" alt="moonbug logo" width="256"/>

Single-file, in-process, DAP powered Lua debugger for your favorite code editor!

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

Requires you have [mfussenegger/nvim-dap](https://github.com/mfussenegger/nvim-dap) installed:

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

- [Visual Studio Code Extension Store](https://marketplace.visualstudio.com/items?itemName=atomicptr.vscode-moonbug)
- [Github](https://github.com/atomicptr/vscode-moonbug)

### Zed

We have an official Zed extension available here:

- Zed Extensions (coming soon...)
- [Github](https://github.com/atomicptr/zed-moonbug)

### Defold

We have an official [Defold Game Engine](https://defold.com/) library available here: [atomicptr/defold-moonbug](http://github.com/atomicptr/defold-moonbug)

## Supported Lua Versions

- LuaJIT 2.x
- Lua 5.4
- Lua 5.5

## Dependencies

- **JSON**: We need JSON for DAP related interactions, make sure you have one of the following available:
    - [cjson](https://github.com/Davegamble/cjson)
    - [json.lua](https://github.com/rxi/json.lua)
    - Global `json` object (e.g. Defold)
- [luasocket](https://github.com/lunarmodules/luasocket): For interacting with DAP clients

You can overwrite which library you use, or integrate a different one via the `moonbug.compat` table, first lets look
at the type signature:

```lua
---@class moonbug.Compat
---@field libs      moonbug.compat.Libs
---@field log_print fun(message: string)

---@class moonbug.compat.Libs
---@field socket? moonbug.compat.SocketLib
---@field json?   moonbug.compat.JsonLib

---@class moonbug.compat.SocketLib
---@field bind    fun(host: string, port: integer): moonbug.Socket
---@field gettime fun(): integer

---@class moonbug.compat.JsonLib
---@field encode fun(v: any): string|nil
---@field decode fun(s: string): any
```

This means as long as you provide another function with the same shape & functionality you can just replace them, e.g.

```lua
local moonbug = require "moonbug"

-- lets use "dkjson" as our json implementation
local json = require "dkjson"

moonbug.compat.libs.json = {
    encode = json.encode,
    decode = function(s)
        local res, _, err = json.decode(s)
        if err ~= nil then
            error(err)
        end

        return res
    end,
}

-- alternative, we could just write, because the shape is basically the same as ours
moonbug.compat.libs.json = require "dkjson"

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

## Special Thanks

Special thanks to

- [pkulchenko/MobDebug](https://github.com/pkulchenko/MobDebug): Primary inspiration and learnt a lot through reading it
- [tomblind/local-lua-debugger-vscode](https://github.com/tomblind/local-lua-debugger-vscode)

## License

MIT
