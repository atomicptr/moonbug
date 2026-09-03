local moonbug = require "src.moonbug"

moonbug.listen("127.0.0.1", 8888, { wait = true })

local function div1(a, b)
    if b == 0 then
        error "division by zero"
    end

    return a / b
end

local function div2(a, b)
    assert(b ~= 0, "division by zero")
    return a / b
end

print(div1(10, 2))
-- print(div1(10, 0))
print(div2(10, 2))
-- print(div2(10, 0))

local ok, res = pcall(div2, 10, 0)
if ok then
    print("ok", res)
else
    print("err", res)
end

print "yolo"
