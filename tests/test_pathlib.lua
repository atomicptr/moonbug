local moonbug = require "src.moonbug"
local p = moonbug._internal

test("path_is_absolute detects posix paths", function()
    expect.eq(true, p.path_is_absolute "/home/christopher/dev/lua/moonbug")
    expect.eq(true, p.path_is_absolute "/")
end)

test("path_is_absolute detects windows paths", function()
    expect.eq(true, p.path_is_absolute "C:/users/me/a.lua")
    expect.eq(true, p.path_is_absolute "C:\\users\\me\\a.lua")
end)

test("path_is_absolute rejects relative and chunk paths", function()
    expect.eq(false, p.path_is_absolute "examples/01-wait.lua")
    expect.eq(false, p.path_is_absolute "01-wait.lua")
    expect.eq(false, p.path_is_absolute "@examples/01-wait.lua")
    expect.eq(false, p.path_is_absolute "")
end)

test("path_join joins segments with '/'", function()
    expect.eq("a/b/c.lua", p.path_join("a", "b", "c.lua"))
    expect.eq("/root/examples/01-wait.lua", p.path_join("/root", "examples", "01-wait.lua"))
end)

test("path_join skips empty and nil parts", function()
    expect.eq("a/b", p.path_join("a", "", "b"))
    expect.eq("a/b", p.path_join("a", nil, "b"))
    expect.eq("", p.path_join("", "", ""))
end)

test("path_join collapses duplicate slashes", function()
    expect.eq("a/b", p.path_join("a/", "/b"))
    expect.eq("/a/b/c/", p.path_join("/a/", "/b/", "/c/"))
end)

test("path_normalize strips the '@' chunk marker", function()
    expect.eq("examples/01-wait.lua", p.path_normalize "@examples/01-wait.lua")
end)

test("path_normalize converts backslashes to slashes", function()
    expect.eq("a/b/c.lua", p.path_normalize "a\\b\\c.lua")
end)

test("path_normalize resolves '..' segments", function()
    expect.eq("/a/c", p.path_normalize "/a/b/../c")
    expect.eq("/c", p.path_normalize "/a/../../c")
    expect.eq("a/c.lua", p.path_normalize "a/b/../c.lua")
end)

test("path_normalize keeps posix roots", function()
    expect.eq("/home/user/proj/x.lua", p.path_normalize "/home/user/proj/x.lua")
    expect.eq("/", p.path_normalize "/")
end)

test("path_normalize keeps windows drive prefixes", function()
    expect.eq("C:/Users/me/x.lua", p.path_normalize "C:\\Users\\me\\x.lua")
end)

test("path_normalize returns '' for empty input", function()
    expect.eq("", p.path_normalize "")
end)

test("path_normalize is idempotent", function()
    local samples = {
        "@examples/01-wait.lua",
        "/home/user/proj/../x.lua",
        "a\\b\\..\\c.lua",
        "C:\\Users\\me\\x.lua",
    }
    for _, s in ipairs(samples) do
        expect.eq(p.path_normalize(s), p.path_normalize(p.path_normalize(s)))
    end
end)

test("path_resolve lets absolute targets win over root_dir", function()
    expect.eq("/abs/x.lua", p.path_resolve("/abs/x.lua", "/root"))
    expect.eq("/abs/x.lua", p.path_resolve("@/abs/x.lua", "/root"))
end)

test("path_resolve joins relative targets against root_dir", function()
    expect.eq("/proj/examples/01-wait.lua", p.path_resolve("examples/01-wait.lua", "/proj"))
    expect.eq("/a/b/sub/x.lua", p.path_resolve("sub/x.lua", "/a/b"))
end)

test("path_resolve strips '@' before joining", function()
    expect.eq("/proj/examples/01-wait.lua", p.path_resolve("@examples/01-wait.lua", "/proj"))
end)

test("path_resolve returns normalized target when root_dir is missing", function()
    expect.eq("examples/01-wait.lua", p.path_resolve("examples/01-wait.lua", nil))
    expect.eq("examples/01-wait.lua", p.path_resolve("examples/01-wait.lua", ""))
end)

test("regression: breakpoint key and runtime source resolve identically", function()
    local root = "/home/christopher/dev/lua/moonbug"
    local bp_key = p.path_resolve(root .. "/examples/01-wait.lua", root)
    local runtime_key = p.path_resolve("@examples/01-wait.lua", root)
    expect.eq(bp_key, runtime_key)
end)
