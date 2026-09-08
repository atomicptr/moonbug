print "Hello, World!" -- @bp1

local t = coroutine.create(function()
    print "Hello From Threads" -- @bp2
end)

local ok, err = coroutine.resume(t)
assert(ok, err)

-- wait until dead
while true do
    local status = coroutine.status(t)
    if status == "dead" then
        break
    end
end

print "Its finally over" -- @bp3
