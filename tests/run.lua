-- simple test runner for moonbug

if not os.getenv "MOONBUG_TEST" then
    error "Run tests using ./run_tests.sh"
end

local passed = 0
local failed = 0

local color_red = "\27[31;1m"
local color_green = "\27[32m"
local color_reset = "\27[0m"
local color_bold = "\27[1m"

local function paint(text, color)
    if os.getenv "NO_COLOR" then
        return text
    end

    return color .. text .. color_reset
end

_G.expect = {
    ---@param expected any
    ---@param actual   any
    ---@param hint?    string
    eq = function(expected, actual, hint)
        if expected ~= actual then
            error(
                string.format(
                    "%sexpect.eq: expected %s == %s",
                    hint and (hint .. ": ") or "",
                    tostring(expected),
                    tostring(actual)
                ),
                3
            )
        end
    end,
    neq = function(expected, actual, hint)
        if expected == actual then
            error(
                string.format(
                    "%sexpect.neq: expected %s ~= %s",
                    hint and (hint .. ": ") or "",
                    tostring(expected),
                    tostring(actual)
                ),
                3
            )
        end
    end,
    is_nil = function(expected, hint)
        if expected ~= nil then
            error(
                string.format("%sexpect.is_nil: expected %s == nil", hint and (hint .. ": ") or "", tostring(expected)),
                3
            )
        end
    end,
    not_nil = function(expected, hint)
        if expected == nil then
            error(
                string.format("%sexpect.not_nil: expected %s ~= nil", hint and (hint .. ": ") or "", tostring(expected)),
                3
            )
        end
    end,
    tbl_eq = function(expected, actual, hint)
        if #expected ~= #actual then
            error(
                string.format(
                    "%stbl_eq: expected count %d == actual count %d",
                    hint and (hint .. ": ") or "",
                    #expected,
                    #actual
                ),
                3
            )
        end

        for k in pairs(expected) do
            local expected_val = expected[k]
            local actual_val = actual[k]

            if expected_val ~= actual_val then
                error(
                    string.format(
                        "%stbl_eq: expected[%s] %s == actual[%s] %s",
                        hint and (hint .. ": ") or "",
                        k,
                        expected_val,
                        k,
                        actual_val
                    ),
                    3
                )
            end
        end
    end,
}

---@param name string
---@param fn   fun()
_G.test = function(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1

        print()

        print(paint("  FAIL | " .. name, color_red))
        print(paint("    " .. tostring(err):gsub("\n", "\n      "), color_red))

        for line in debug.traceback():gmatch "[^\n]+" do
            print(paint("      " .. line, color_red))
        end

        print()

        return
    end

    passed = passed + 1
    print(paint("  OK   | " .. name, color_green))
end

local function collect_tests()
    local names = {}

    local handle, handle_err = io.popen "printf '%s\\n' tests/test_*.lua 2>/dev/null"
    if handle_err ~= nil then
        error(handle_err)
    end
    assert(handle)

    for line in handle:lines() do
        names[#names + 1] = line
    end

    handle:close()

    table.sort(names)
    return names
end

local tests = collect_tests()
if #tests == 0 then
    error "no test files found (expected tests/test_*.lua)"
end

print()

for _, path in ipairs(tests) do
    print(paint("=======> " .. path, color_bold))

    local ok, err = pcall(dofile, path)
    if not ok then
        failed = failed + 1
        print(string.format("could not load test %s: %s", path, tostring(err)))
    end

    print()
end

print(string.format(paint("       | %d passed, %d failed", color_bold), passed, failed))
os.exit(failed == 0 and 0 or 1)
