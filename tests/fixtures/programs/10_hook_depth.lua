local function failing()
    error "expected"
end

local function protected()
    pcall(failing)
end

local function leaf()
    return 1
end

local function tail()
    return leaf()
end

for _ = 1, 100 do
    protected()
    tail()
    tail()
end

local value = 1 -- @after_churn
value = tail() -- @call
value = value + 1 -- @after_call

print("HOOK_DEPTH_DONE", value)
