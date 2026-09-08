local function caught_failure()
    error "caught failure" -- @caught
end

local ok, caught_message = pcall(caught_failure)
print("CAUGHT", ok, caught_message)

local function uncaught_failure()
    error "uncaught failure" -- @uncaught
end

uncaught_failure()
