local function inspect(number, label)
    local value = number -- @breakpoint
    print(value, label)
end

inspect(42, "answer")
