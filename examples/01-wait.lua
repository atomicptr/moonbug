local moonbug = require "src.moonbug"

moonbug.listen("127.0.0.1", 8888, { wait = true })

local person = {
    name = "Peter",
    age = 37,
    hobbies = { "Programming", "Judo" },
    secret = {
        that = {
            is = {
                deep = {
                    inside = {
                        "yolo",
                    },
                },
            },
        },
    },
    long_list = {},
}

for i = 1, 10000 do
    table.insert(person.long_list, "Hello: " .. i)
end

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

    print(person.name, person.age)
end

main()
