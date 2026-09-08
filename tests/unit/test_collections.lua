local moonbug = require "src.moonbug"

local collections = moonbug._test.collections

test("slice: count=0 with no start returns everything, with start returns the tail", function()
    local list = { "a", "b", "c", "d" }
    expect.eq(4, #collections.slice(list))
    expect.eq(3, #collections.slice(list, 1))
    expect.eq("b", collections.slice(list, 1, 0)[1]) -- count 0 means "rest", but only when start is set
    expect.eq(4, #collections.slice(list, nil, 0)) -- no start + count 0 = get all (per spec)
end)

test("table_array_length walks raw array slots, holes stop it", function()
    expect.eq(3, collections.table_array_length { 10, 20, 30 })
    expect.eq(1, collections.table_array_length { [1] = "x", [3] = "y" }) -- hole at 2
    expect.eq(0, collections.table_array_length { [2] = "x" }) -- nothing at 1
end)

test("table_named_keys is sorted and matches table_named_count", function()
    local t = { 1, 2, [100] = "far", z = 1, a = 2 }
    local keys = collections.table_named_keys(t, 2)

    expect.tbl_eq({ 100, "a", "z" }, keys)
    expect.eq(3, collections.table_named_count(t, 2))
end)
