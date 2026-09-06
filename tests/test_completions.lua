local moonbug = require "src.moonbug"
local dap = require "tests.utils_dap"

local p = moonbug._internal

before_each(function()
    p.reset()
end)

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

test("split_completion_input splits plain identifiers", function()
    local base, prefix, sep = p.split_completion_input("foo", 4)

    expect.is_nil(base)
    expect.eq("foo", prefix)
    expect.eq("", sep)
end)

test("split_completion_input splits member access with a prefix", function()
    local base, prefix, sep = p.split_completion_input("foo.b", 6)

    expect.eq("foo", base)
    expect.eq("b", prefix)
    expect.eq(".", sep)
end)

test("split_completion_input handles an empty field prefix after '.'", function()
    local base, prefix, sep = p.split_completion_input("foo.", 5)

    expect.eq("foo", base)
    expect.eq("", prefix)
    expect.eq(".", sep)
end)

test("split_completion_input handles ':' separators", function()
    local base, prefix, sep = p.split_completion_input("person:", 8)
    expect.eq("person", base)
    expect.eq("", prefix)
    expect.eq(":", sep)
end)

test("split_completion_input keeps earlier dots in the base expression", function()
    local base, prefix, sep = p.split_completion_input("a.b.gr", 7)

    expect.eq("a.b", base)
    expect.eq("gr", prefix)
    expect.eq(".", sep)
end)

test("split_completion_input: caret inside a bare word returns the partial word", function()
    local base, prefix, sep = p.split_completion_input("foobar", 4)
    expect.is_nil(base)
    expect.eq("foob", prefix)
    expect.eq("", sep)
end)

test("split_completion_input: dashes are not member separators", function()
    local base, prefix, _ = p.split_completion_input("foo-bar", 5)
    expect.is_nil(base) -- no '.'/':' → no member completion
    expect.eq("b", prefix)
end)

test("split_completion_input treats a caret in the middle of an identifier as bare", function()
    local base, prefix, sep = p.split_completion_input("foo.bar", 3)

    expect.is_nil(base)
    expect.eq("foo", prefix)
    expect.eq("", sep)
end)

test("complete_fields: ':' offers methods but not plain fields", function()
    local person = make_person()

    local targets = p.complete_fields(person, "", ":")
    local l = labels(targets)

    expect.tbl_eq({ "greet" }, l)
    expect.eq("function", targets[1].type)
end)

test("complete_fields: '.' offers fields and methods", function()
    local person = make_person()

    local targets = p.complete_fields(person, "", ".")
    local l = labels(targets)

    expect.tbl_eq({ "age", "greet", "name" }, l)
end)

test("complete_fields: prefix filtering works for both separators", function()
    local person = make_person()

    local colon = labels(p.complete_fields(person, "gr", ":"))
    expect.tbl_eq({ "greet" }, colon)

    local dot = labels(p.complete_fields(person, "a", "."))
    expect.tbl_eq({ "age" }, dot)
end)

test("complete_fields: an own key shadows the inherited method", function()
    local Person = {}
    Person.__index = Person
    function Person:greet() end

    local person = setmetatable({ greet = 42 }, Person)

    expect.eq(0, #p.complete_fields(person, "", ":"))
    expect.tbl_eq({ "greet" }, labels(p.complete_fields(person, "", ".")))
end)

test("complete_fields: stops at a function __index and still lists own keys", function()
    local person = setmetatable({ alpha = 1 }, {
        __index = function() end,
    })

    local l = labels(p.complete_fields(person, "", "."))
    expect.tbl_eq({ "alpha" }, l)
end)

test("complete_fields: terminates on circular __index chains", function()
    local a = { a1 = 1 }
    local b = { b1 = 2 }
    setmetatable(a, { __index = b })
    setmetatable(b, { __index = a })

    local l = labels(p.complete_fields(a, "", "."))
    expect.tbl_eq({ "a1", "b1" }, l)
end)

test("complete_fields: does not offer callable tables on ':'", function()
    local callable = setmetatable({}, { __call = function() end })
    local t = { run = callable }

    expect.eq(0, #p.complete_fields(t, "", ":"))

    local l = labels(p.complete_fields(t, "", "."))
    expect.tbl_eq({ "run" }, l)
end)

test("complete_fields: results are sorted by label", function()
    local t = { zed = 1, alpha = 2, middle = 3 }

    local l = labels(p.complete_fields(t, "", "."))
    expect.tbl_eq({ "alpha", "middle", "zed" }, l)
end)

test("complete_identifiers includes upvalues of the frame function", function()
    local outer_counter = 42

    local function scenario()
        return p.complete_identifiers(p.get_main_thread(), 1, "outer")
    end

    local l = labels(scenario())
    expect.eq(true, l[1] == "outer_counter")
end)

test("complete_identifiers completes locals and upvalues of a frame", function()
    local function scenario()
        local alpha = 1
        local betta = 2
        local charlie = 3

        local targets = p.complete_identifiers(p.get_main_thread(), 1, "ch")
        local by_name = {}
        for _, t in ipairs(targets) do
            by_name[t.label] = t
        end

        return by_name, alpha + betta + charlie
    end

    local by_name = scenario()

    expect.not_nil(by_name["charlie"])
    expect.eq("variable", by_name["charlie"].type)
    expect.is_nil(by_name["alpha"]) -- filtered out by the "ch" prefix
    expect.is_nil(by_name["betta"])
end)

test("complete_identifiers with an empty prefix returns everything, sorted", function()
    local function scenario()
        return p.complete_identifiers(p.get_main_thread(), 1, "")
    end

    local targets = scenario()
    expect.eq(true, #targets > 0)

    for i = 2, #targets do
        expect.eq(true, targets[i - 1].label <= targets[i].label, "sorted")
    end
end)

test("completions request: '.' shows fields and methods through the real path", function()
    dap.with_socket_pair(function(peer, conn)
        local function scenario()
            p.session.client = conn
            p.session.ready = true
            p.session.paused = true
            p.get_main_context().frames[1] = 1

            local person = make_person()

            local req = {
                type = "request",
                command = "completions",
                seq = 1,
                arguments = { frameId = 1, text = "person.", column = 7 },
            }
            p.dispatch(req)

            return dap.read_msg(peer)
        end

        local resp = scenario()
        dap.expect_response(resp, { type = "request", command = "completions", seq = 1 }, true)

        expect.tbl_eq({ "age", "greet", "name" }, labels(resp.body.targets))
    end)
end)

test("completions request: member completion on a table field base (a.b.)", function()
    dap.with_socket_pair(function(peer, conn)
        local function scenario()
            p.session.client = conn
            p.session.ready = true
            p.session.paused = true
            p.get_main_context().frames[1] = 1

            local person = make_person()
            local wrapper = { person = person }

            local req = {
                type = "request",
                command = "completions",
                seq = 1,
                arguments = { frameId = 1, text = "wrapper.person:", column = 17 },
            }
            p.dispatch(req)

            return dap.read_msg(peer)
        end

        local resp = scenario()
        dap.expect_response(resp, { type = "request", command = "completions", seq = 1 }, true)

        expect.tbl_eq({ "greet" }, labels(resp.body.targets))
    end)
end)

test("completions request: bare prefix items carry start/length so clients replace, not append", function()
    dap.with_socket_pair(function(peer, conn)
        local function scenario()
            p.session.client = conn
            p.session.ready = true
            p.session.paused = true
            p.get_main_context().frames[1] = 1

            -- "coro" is a prefix of the global `coroutine`
            local req = {
                type = "request",
                command = "completions",
                seq = 1,
                arguments = { frameId = 1, text = "coro", column = 5 },
            }
            p.dispatch(req)

            return dap.read_msg(peer)
        end

        local resp = scenario()
        dap.expect_response(resp, { type = "request", command = "completions", seq = 1 }, true)

        local coroutine_item
        for _, t in ipairs(resp.body.targets) do
            if t.label == "coroutine" then
                coroutine_item = t
            end
        end

        expect.not_nil(coroutine_item, "coroutine should be offered for 'coro'")

        -- start/length define the overwritten range inside args.text ("coro" -> chars 0..3)
        expect.eq(0, coroutine_item.start, "start of the typed prefix")
        expect.eq(4, coroutine_item.length, "length of the typed prefix")
    end)
end)

test("completions request: member items replace only the field prefix after ':'", function()
    dap.with_socket_pair(function(peer, conn)
        local function scenario()
            p.session.client = conn
            p.session.ready = true
            p.session.paused = true
            p.get_main_context().frames[1] = 1

            local person = make_person()

            local req = {
                type = "request",
                command = "completions",
                seq = 1,
                arguments = { frameId = 1, text = "person:gr", column = 9 },
            }
            p.dispatch(req)

            return dap.read_msg(peer)
        end

        local resp = scenario()
        dap.expect_response(resp, { type = "request", command = "completions", seq = 1 }, true)

        local greet_item
        for _, t in ipairs(resp.body.targets) do
            if t.label == "greet" then
                greet_item = t
            end
        end

        expect.not_nil(greet_item)
        expect.eq(7, greet_item.start, "0-based offset of 'gr' in 'person:gr'")
        expect.eq(2, greet_item.length, "length of the field prefix 'gr'")
    end)
end)

test("split_completion_input reports the 0-based prefix offset", function()
    local base, prefix, _, start = p.split_completion_input("coro", 5)
    expect.is_nil(base)
    expect.eq("coro", prefix)
    expect.eq(0, start)

    local b2, p2, _, start2 = p.split_completion_input("person:gr", 9)
    expect.eq("person", b2)
    expect.eq("gr", p2)
    expect.eq(7, start2)
end)
