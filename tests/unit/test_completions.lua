local moonbug = require "src.moonbug"

local comp = moonbug._test.completions

local function make_person()
    local Person = {}
    Person.__index = Person
    function Person:greet() end

    local person = setmetatable({ name = "Peter", age = 37 }, Person)
    return person
end

---@param targets table
---@return string[]
local function labels(targets)
    local out = {}
    for _, t in ipairs(targets) do
        out[#out + 1] = t.label
    end
    table.sort(out)
    return out
end

test("split_input splits plain identifiers", function()
    local base, prefix, sep = comp.split_input("foo", 4)

    expect.is_nil(base)
    expect.eq("foo", prefix)
    expect.eq("", sep)
end)

test("split_input splits member access with a prefix", function()
    local base, prefix, sep = comp.split_input("foo.b", 6)

    expect.eq("foo", base)
    expect.eq("b", prefix)
    expect.eq(".", sep)
end)

test("split_input handles an empty field prefix after '.'", function()
    local base, prefix, sep = comp.split_input("foo.", 5)

    expect.eq("foo", base)
    expect.eq("", prefix)
    expect.eq(".", sep)
end)

test("split_input handles ':' separators", function()
    local base, prefix, sep = comp.split_input("person:", 8)
    expect.eq("person", base)
    expect.eq("", prefix)
    expect.eq(":", sep)
end)

test("split_input keeps earlier dots in the base expression", function()
    local base, prefix, sep = comp.split_input("a.b.gr", 7)

    expect.eq("a.b", base)
    expect.eq("gr", prefix)
    expect.eq(".", sep)
end)

test("split_input: caret inside a bare word returns the partial word", function()
    local base, prefix, sep = comp.split_input("foobar", 4)
    expect.is_nil(base)
    expect.eq("foob", prefix)
    expect.eq("", sep)
end)

test("split_input: dashes are not member separators", function()
    local base, prefix, _ = comp.split_input("foo-bar", 5)
    expect.is_nil(base) -- no '.'/':' → no member completion
    expect.eq("b", prefix)
end)

test("split_input treats a caret in the middle of an identifier as bare", function()
    local base, prefix, sep = comp.split_input("foo.bar", 3)

    expect.is_nil(base)
    expect.eq("foo", prefix)
    expect.eq("", sep)
end)

test("split_input reports the 0-based prefix offset", function()
    local base, prefix, _, start = comp.split_input("coro", 5)
    expect.is_nil(base)
    expect.eq("coro", prefix)
    expect.eq(0, start)

    local b2, p2, _, start2 = comp.split_input("person:gr", 9)
    expect.eq("person", b2)
    expect.eq("gr", p2)
    expect.eq(7, start2)
end)

test("complete_fields: ':' offers methods but not plain fields", function()
    local person = make_person()

    local targets = comp.complete_fields(person, "", ":")
    local l = labels(targets)

    expect.tbl_eq({ "greet" }, l)
    expect.eq("function", targets[1].type)
end)

test("complete_fields: '.' offers fields and methods", function()
    local person = make_person()

    local targets = comp.complete_fields(person, "", ".")
    local l = labels(targets)

    expect.tbl_eq({ "age", "greet", "name" }, l)
end)

test("complete_fields: prefix filtering works for both separators", function()
    local person = make_person()

    local colon = labels(comp.complete_fields(person, "gr", ":"))
    expect.tbl_eq({ "greet" }, colon)

    local dot = labels(comp.complete_fields(person, "a", "."))
    expect.tbl_eq({ "age" }, dot)
end)

test("complete_fields: an own key shadows the inherited method", function()
    local Person = {}
    Person.__index = Person
    function Person:greet() end

    local person = setmetatable({ greet = 42 }, Person)

    expect.eq(0, #comp.complete_fields(person, "", ":"))
    expect.tbl_eq({ "greet" }, labels(comp.complete_fields(person, "", ".")))
end)

test("complete_fields: stops at a function __index and still lists own keys", function()
    local person = setmetatable({ alpha = 1 }, {
        __index = function() end,
    })

    local l = labels(comp.complete_fields(person, "", "."))
    expect.tbl_eq({ "alpha" }, l)
end)

test("complete_fields: terminates on circular __index chains", function()
    local a = { a1 = 1 }
    local b = { b1 = 2 }
    setmetatable(a, { __index = b })
    setmetatable(b, { __index = a })

    local l = labels(comp.complete_fields(a, "", "."))
    expect.tbl_eq({ "a1", "b1" }, l)
end)

test("complete_fields: does not offer callable tables on ':'", function()
    local callable = setmetatable({}, { __call = function() end })
    local t = { run = callable }

    expect.eq(0, #comp.complete_fields(t, "", ":"))

    local l = labels(comp.complete_fields(t, "", "."))
    expect.tbl_eq({ "run" }, l)
end)

test("complete_fields: results are sorted by label", function()
    local t = { zed = 1, alpha = 2, middle = 3 }

    local l = labels(comp.complete_fields(t, "", "."))
    expect.tbl_eq({ "alpha", "middle", "zed" }, l)
end)
