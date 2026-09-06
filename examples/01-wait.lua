local moonbug = require "src.moonbug"

moonbug.listen("127.0.0.1", 8888, { wait = true })

local Person = {}
Person.__index = Person

function Person:greet()
    print("Hello, ", self.name)
end

local person = setmetatable({
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
}, Person)

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
    add(x)

    x = x * 2

    print(value)
    add(x)

    print(value)

    print(person.name, person.age)
end

main()
