-- generic module to import and test stuff
local M = {}

function M.greet(name)
    name = name or "World"

    local message = string.format("Hello, %s!", name)

    print(message)
end

return M
