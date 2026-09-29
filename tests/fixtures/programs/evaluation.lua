local captured = 20

local function inspect(...)
    local value = 10
    local name = "Peter"
    local nested = { answer = 42 } -- @breakpoint

    print(value, captured, nested.answer, select("#", ...)) -- @set_variable
end

inspect("one", "two")
