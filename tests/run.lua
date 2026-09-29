-- simple test runner for moonbug

if not os.getenv "MOONBUG_TEST" then
    error "Run tests using ./run_tests.sh"
end

local expect_default_level = 2

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

---@param expected table
---@param actual   table
---@param test     "expected"|"actual"
---@param hint?    string
local function expect_same_for(expected, actual, test, hint)
    local tbl = expected

    if test == "actual" then
        tbl = actual
    end

    for k in pairs(tbl) do
        local expected_val = expected[k]
        local actual_val = actual[k]

        if type(expected_val) == "table" or type(actual_val) == "table" then
            expect_same_for(expected_val, actual_val, test)
        end

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
                expect_default_level + 1
            )
        end
    end
end

---@type function|nil
local before_each_runner = nil

---@type function|nil
local after_each_runner = nil

_G.before_each = function(fn)
    before_each_runner = fn
end

_G.after_each = function(fn)
    after_each_runner = fn
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
                expect_default_level
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
                expect_default_level
            )
        end
    end,
    is_nil = function(expected, hint)
        if expected ~= nil then
            error(
                string.format("%sexpect.is_nil: expected %s == nil", hint and (hint .. ": ") or "", tostring(expected)),
                expect_default_level
            )
        end
    end,
    not_nil = function(expected, hint)
        if expected == nil then
            error(
                string.format("%sexpect.not_nil: expected %s ~= nil", hint and (hint .. ": ") or "", tostring(expected)),
                expect_default_level
            )
        end
    end,
    is_true = function(expected, hint)
        if expected ~= true then
            error(
                string.format(
                    "%sexpect.is_true: expected %s == true",
                    hint and (hint .. ": ") or "",
                    tostring(expected)
                ),
                expect_default_level
            )
        end
    end,
    is_false = function(expected, hint)
        if expected ~= false then
            error(
                string.format(
                    "%sexpect.is_false: expected %s == false",
                    hint and (hint .. ": ") or "",
                    tostring(expected)
                ),
                expect_default_level
            )
        end
    end,
    tbl_length = function(expected_length, tbl, hint)
        assert(type(tbl) == "table")

        if #tbl ~= expected_length then
            error(
                string.format(
                    "%sexpect.tbl_length: expected table length to be %d but got %d instead",
                    hint and (hint .. ": ") or "",
                    expected_length,
                    #tbl
                ),
                expect_default_level
            )
        end
    end,
    tbl_eq = function(expected, actual, hint)
        expect_same_for(expected, actual, "expected", hint)
        expect_same_for(expected, actual, "actual", hint) -- reverse
    end,
}

---@param name string
---@param fn   fun()
_G.test = function(name, fn)
    local ok, err = pcall(function()
        if before_each_runner then
            before_each_runner()
        end

        fn()
    end)

    -- run the after hook even if test fails
    local after_ok, after_err = pcall(function()
        if after_each_runner then
            after_each_runner()
        end
    end)

    if not after_ok then
        print(paint(string.format("- failed to execute after hook: %s", after_err)), color_red)
    end

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
    print(paint("    OK | " .. name, color_green))
end

local function collect_tests()
    local names = {}

    local handle, handle_err = io.popen "find tests -maxdepth 2 -type f -name 'test_*.lua' -print"
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

    -- reset before/after each functions
    before_each(nil)
    after_each(nil)

    local ok, err = pcall(dofile, path)
    if not ok then
        failed = failed + 1

        print()
        print(paint(string.format("  FAIL | could not load test %s: %s", path, tostring(err)), color_red))
    end

    print()
end

print(string.format(paint("       | %d passed, %d failed", color_bold), passed, failed))
os.exit(failed == 0 and 0 or 1)
