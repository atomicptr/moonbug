local captured = 20

local function inspect(...)
    local value = 10
    local nested = { answer = 42 } -- @breakpoint

    print(value, captured, nested.answer, select("#", ...))
end

inspect("one", "two")
