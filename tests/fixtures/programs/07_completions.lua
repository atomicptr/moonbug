completion_global = "global"

local completion_upvalue = "upvalue"

local Person = {}
Person.__index = Person

function Person:greet()
    return "hello"
end

function Person:grow()
    return "older"
end

local function inspect()
    local completion_local = "local"
    local person = setmetatable({
        name = "Peter",
        age = 37,
    }, Person)
    local wrapper = {
        person = person,
    }
    local running = true

    if completion_local == completion_upvalue then
        print "unreachable"
    end

    person.name = person.name -- @breakpoint

    while running do
        running = running
    end

    print(wrapper.person.name)
end

inspect()
