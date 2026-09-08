local port = assert(tonumber(arg[1]), "missing port")
local program = assert(arg[2], "missing program")

local moonbug = require "src.moonbug"

moonbug.listen("127.0.0.1", port, {
    wait = true,
    max_wait_time = 5,
    eval_timeout = tonumber(os.getenv "MOONBUG_EVAL_TIMEOUT") or 5,
})

local chunk = assert(loadfile(program))
chunk()
