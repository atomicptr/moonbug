local moonbug = require "src.moonbug"

local p = moonbug._internal

test("slice: count=0 with no start returns everything, with start returns the tail", function()
    local list = { "a", "b", "c", "d" }
    expect.eq(4, #p.slice(list))
    expect.eq(3, #p.slice(list, 1))
    expect.eq("b", p.slice(list, 1, 0)[1]) -- count 0 means "rest", but only when start is set
    expect.eq(4, #p.slice(list, nil, 0)) -- no start + count 0 = get all (per spec)
end)

test("table_array_length walks raw array slots, holes stop it", function()
    expect.eq(3, p.table_array_length { 10, 20, 30 })
    expect.eq(1, p.table_array_length { [1] = "x", [3] = "y" }) -- hole at 2
    expect.eq(0, p.table_array_length { [2] = "x" }) -- nothing at 1
end)

test("table_named_keys is sorted and matches table_named_count", function()
    local t = { 1, 2, [100] = "far", z = 1, a = 2 }
    local keys = p.table_named_keys(t, 2)

    expect.tbl_eq({ 100, "a", "z" }, keys)
    expect.eq(3, p.table_named_count(t, 2))
end)

test("serialize_value: scalars carry no variablesReference", function()
    p.reset()

    local s = p.serialize_value(42, "answer")
    expect.eq("answer", s.name)
    expect.eq("number", s.type)
    expect.eq("42", s.value)
    expect.eq(0, s.variablesReference)
end)

test("serialize_value: tables register a ref and report both partitions", function()
    p.reset()

    local s = p.serialize_value({ 1, 2, x = 3 }, "t")
    expect.eq(2, s.indexedVariables) -- rawget walk
    expect.eq(1, s.namedVariables) -- "x"

    local ref = p.session.variables.refs[s.variablesReference]
    expect.not_nil(ref)
    expect.eq("table", ref.kind)
end)

test("error_is_caught is true under pcall, false on a pcall-free stack", function()
    local ok, caught = pcall(function()
        return p.error_is_caught()
    end)

    expect.eq(true, ok)
    expect.eq(true, caught)

    local co = coroutine.create(function()
        return p.error_is_caught()
    end)

    local ok2, plain = coroutine.resume(co)
    expect.eq(true, ok2)
    expect.eq(false, plain)
end)
