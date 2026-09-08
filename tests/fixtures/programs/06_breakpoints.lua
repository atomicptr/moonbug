for i = 1, 4 do
    local conditional = i -- @conditional
    local hit = i -- @hit
    local logged = i -- @logpoint
    print("VISIT", conditional, hit, logged)
end

for i = 1, 2 do
    local repeated = i
    print("REPEAT", repeated) -- @repeated
end
