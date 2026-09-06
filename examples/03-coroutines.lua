local moonbug = require "src.moonbug"

moonbug.listen("127.0.0.1", 8888, { wait = true })

local function do_the_thing(name, i)
    print(name, i)
    coroutine.yield()
end

local function worker(name)
    for i = 1, 5 do
        do_the_thing(name, i)
    end
end

local function main()
    local a = coroutine.create(worker)
    local b = coroutine.create(worker)

    for _ = 1, 5 do
        coroutine.resume(a, "A")
        coroutine.resume(b, "B")
    end
end

main()