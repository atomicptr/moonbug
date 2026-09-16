local moonbug = require "src.moonbug"

local camel2snake = moonbug._test.helpers.camel2snake
local str_starts_with = moonbug._test.helpers.str_starts_with

test("camel2snake converts setExceptionBreakpoints into snake case", function()
    expect.eq("set_exception_breakpoints", camel2snake "setExceptionBreakpoints")
end)

test("camel2snake handles standard boundary conditions and edge cases", function()
    expect.eq("", camel2snake "")
    expect.eq("a", camel2snake "a")
    expect.eq("a", camel2snake "A")
    expect.eq("already_snake_case", camel2snake "already_snake_case")
    expect.eq("pascal_case_string", camel2snake "PascalCaseString")
    expect.eq("v2_api_route", camel2snake "v2ApiRoute")
    expect.eq("foo-bar_baz", camel2snake "foo-barBaz")
    expect.eq("space separated_word", camel2snake "space separatedWord")
end)

test("str_starts_with works correctly", function()
    expect.is_true(str_starts_with("@test", "@"))
    expect.is_true(str_starts_with("@test", "@test"))
    expect.is_true(str_starts_with("test: asdf", "test:"))
    expect.is_false(str_starts_with("test: asdf", "testx"))
    expect.is_false(str_starts_with("", "test"))
    expect.is_true(str_starts_with("", ""))
    expect.is_true(str_starts_with("test", ""))
end)
