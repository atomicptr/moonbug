local function worker()
    local value = 42
    coroutine.yield "ready" -- @coroutine
    return value
end

local thread = coroutine.create(worker)
local ok, result = coroutine.resume(thread)

local suspended = result

ok, result = coroutine.resume(thread) -- @suspended

local finished = coroutine.status(thread)

print(ok, result, suspended, finished) -- @finished
