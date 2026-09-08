local function bump(number)
    local result = number + 1 -- @inside
    return result
end

local value = 1
value = value + 1 -- @start
value = bump(value) -- @call
value = value + 10 -- @after

local running = true
local spins = 0

while running do
    spins = spins + 1 -- @loop
end

print("EXECUTION_DONE", value)
