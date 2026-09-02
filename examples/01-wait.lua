local moonbug = require "src.moonbug"

moonbug.listen("127.0.0.1", 8888, { wait = true })

local value = 1

local function add(num)
    value = value + num
end

local function main()
    local x = 100

    print(value + x)
    add(10)
    print(value)
    add(10)
    print(value)
end

main()
