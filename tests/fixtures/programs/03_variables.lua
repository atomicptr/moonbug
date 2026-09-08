local captured = "captured-value"

local function inspect(first, ...)
    local scalar = 41
    local mixed = {
        "one",
        "two",
        "three",
        "four",
        [10] = "ten",
        alpha = "A",
        zeta = "Z",
    }

    local bad_tostring = setmetatable({}, {
        __tostring = function()
            error "cannot stringify"
        end,
    })

    local large = {}
    for i = 1, 1100 do
        large[i] = i
    end

    local captured_copy = captured -- @first

    mixed[1] = "changed"
    scalar = scalar + 1 -- @second

    print(first, scalar, mixed[1], captured_copy, bad_tostring, #large, select("#", ...))
end

inspect("argument", "vararg")
