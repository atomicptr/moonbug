local moonbug = require "src.moonbug"

local breakpoints = moonbug._test.breakpoints

test("bare number stops on the exact hit count", function()
    for i = 1, 10 do
        expect.eq(i == 5, breakpoints.hit_condition_met("5", i), "hit " .. i)
    end
end)

test("= and == behave like a bare number", function()
    expect.eq(true, breakpoints.hit_condition_met("= 5", 5))
    expect.eq(false, breakpoints.hit_condition_met("= 5", 4))
    expect.eq(true, breakpoints.hit_condition_met("==5", 5))
    expect.eq(false, breakpoints.hit_condition_met("==5", 6))
end)

test("comparison operators", function()
    expect.eq(false, breakpoints.hit_condition_met("> 5", 5))
    expect.eq(true, breakpoints.hit_condition_met("> 5", 6))
    expect.eq(false, breakpoints.hit_condition_met(">= 5", 4))
    expect.eq(true, breakpoints.hit_condition_met(">= 5", 5))
    expect.eq(true, breakpoints.hit_condition_met("< 5", 4))
    expect.eq(false, breakpoints.hit_condition_met("< 5", 5))
    expect.eq(true, breakpoints.hit_condition_met("<= 5", 5))
    expect.eq(false, breakpoints.hit_condition_met("<= 5", 6))
end)

test("~= and != match anything except the given count", function()
    expect.eq(true, breakpoints.hit_condition_met("~= 5", 4))
    expect.eq(false, breakpoints.hit_condition_met("~= 5", 5))
    expect.eq(true, breakpoints.hit_condition_met("!= 5", 6))
    expect.eq(false, breakpoints.hit_condition_met("!= 5", 5))
end)

test("% matches every Nth hit", function()
    for i = 1, 12 do
        expect.eq(i % 3 == 0, breakpoints.hit_condition_met("% 3", i), "hit " .. i)
    end
end)

test("% 0 never matches instead of raising", function()
    expect.eq(false, breakpoints.hit_condition_met("% 0", 1))
    expect.eq(false, breakpoints.hit_condition_met("% 0", 100))
end)

test("surrounding whitespace is ignored", function()
    expect.eq(true, breakpoints.hit_condition_met("  >=  5  ", 5))
    expect.eq(true, breakpoints.hit_condition_met("\t>= 5", 6))
end)

test("malformed hit conditions are rejected as not met", function()
    for _, bad in ipairs { "abc", "> = 5", "-5", "5.5", "5+3", ">= x", "" } do
        expect.eq(false, breakpoints.hit_condition_met(bad, 1), string.format("%q", bad))
    end
end)
