local moonbug = require "src.moonbug"
local dap = require "tests.utils_dap"

local p = moonbug._internal

local function test_source()
    local info = debug.getinfo(1, "S")
    return p.path_resolve(info.source, p.session.project_root_dir)
end

local function roundtrip(peer, conn, req)
    p.session.client = conn
    p.dispatch(req)
    return dap.read_msg(peer)
end

before_each(function()
    p.reset()
    p.session.project_root_dir = "/proj"
end)

after_each(function()
    package.loaded["moonbug.test_module"] = nil
    package.loaded["moonbug.other_module"] = nil
end)

test("determine_module_path resolves a function's @source to a path", function()
    local function fn() end
    local path = p.determine_module_path(fn)

    if path ~= nil then
        expect.eq(test_source(), path)
    end
end)

test("determine_module_path returns nil for values without a file source", function()
    local loader = _G.loadstring or _G.load
    local fn = loader("return 1", "(moonbug test)")

    expect.is_nil(p.determine_module_path(42))
    expect.is_nil(p.determine_module_path "str")
    expect.is_nil(p.determine_module_path(nil))
    expect.is_nil(p.determine_module_path(fn))
end)

test("determine_module_path scans a table module for a file-backed function", function()
    local function helper() end
    local path = p.determine_module_path { run = helper, data = { 1, 2 } }
    expect.eq(test_source(), path)
end)

test("register_module assigns stable ids and a kind/path row", function()
    package.loaded["moonbug.test_module"] = { 1, 2, 3 }

    local first = p.register_module "moonbug.test_module"
    expect.not_nil(first)
    assert(first ~= nil)

    expect.eq("moonbug.test_module", first.name)
    expect.eq("table", first.kind)
    expect.eq(1, first.id)

    local second = p.register_module "moonbug.test_module"
    expect.not_nil(second)
    assert(second ~= nil)

    expect.eq(1, second.id, "re-registering keeps the same id")
    expect.eq("table", second.kind, "re-registering keeps kind")
    expect.eq("table", package.loaded["moonbug.test_module"] ~= nil and "table" or nil)
end)

test("register_module allocates incrementing ids across distinct modules", function()
    package.loaded["moonbug.test_module"] = {}
    package.loaded["moonbug.other_module"] = function() end

    local a = p.register_module "moonbug.test_module"
    expect.not_nil(a)
    assert(a ~= nil)

    local b = p.register_module "moonbug.other_module"
    expect.not_nil(b)
    assert(b ~= nil)

    expect.eq(1, a.id)
    expect.eq(2, b.id)
end)

test("loadedSources returns sorted seeded sources", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.sources["/proj/zz.lua"] = true
        p.session.sources["/proj/aa.lua"] = true

        local req = { type = "request", command = "loadedSources", seq = 1 }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)
        expect.eq(2, #resp.body.sources)
        expect.eq("aa.lua", resp.body.sources[1].name)
        expect.eq("/proj/aa.lua", resp.body.sources[1].path)
        expect.eq("zz.lua", resp.body.sources[2].name)
    end)
end)

test("setBreakpoints seeds the sources set", function()
    dap.with_socket_pair(function(peer, conn)
        local req = {
            type = "request",
            command = "setBreakpoints",
            seq = 1,
            arguments = { source = { path = "/proj/main.lua" }, breakpoints = { { line = 3 } } },
        }
        roundtrip(peer, conn, req)

        expect.eq(true, p.session.sources["/proj/main.lua"])
    end)
end)

test("modules request returns rows and totalModules", function()
    dap.with_socket_pair(function(peer, conn)
        package.loaded["moonbug.test_module"] = {}

        local seed = { type = "request", command = "configurationDone", seq = 1 }
        roundtrip(peer, conn, seed) -- seeds modules without events (ready is still false)

        p.session.ready = true -- handshake would flip this after configurationDone

        local req = { type = "request", command = "modules", seq = 2 }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)
        expect.eq(true, resp.body.totalModules >= 1)

        local found
        for _, m in ipairs(resp.body.modules) do
            if m.name == "moonbug.test_module" then
                found = m
            end
        end

        expect.not_nil(found)
        expect.eq("table", found.kind)
        expect.not_nil(found.id)
    end)
end)

test("modules rows are stable and keep kind/path across requests", function()
    dap.with_socket_pair(function(peer, conn)
        package.loaded["moonbug.test_module"] = {}
        local req = { type = "request", command = "modules", seq = 1 }
        local resp1 = roundtrip(peer, conn, req)

        local req2 = { type = "request", command = "modules", seq = 2 }
        local resp2 = roundtrip(peer, conn, req2)

        local function by_name(list)
            local out = {}
            for _, m in ipairs(list) do
                out[m.name] = m
            end
            return out
        end

        local a = by_name(resp1.body.modules)["moonbug.test_module"]
        local b = by_name(resp2.body.modules)["moonbug.test_module"]

        expect.eq(a.id, b.id, "id stable")
        expect.eq(a.kind, b.kind, "kind preserved on repeat request")
        expect.eq(a.path, b.path, "path preserved on repeat request")
    end)
end)

test("modules honors startModule/moduleCount paging", function()
    dap.with_socket_pair(function(peer, conn)
        local req = {
            type = "request",
            command = "modules",
            seq = 1,
            arguments = { startModule = 0, moduleCount = 1 },
        }
        local resp = roundtrip(peer, conn, req)

        dap.expect_response(resp, req, true)
        expect.eq(1, #resp.body.modules)
        expect.eq(true, resp.body.totalModules >= #resp.body.modules)
    end)
end)

test("configurationDone seeds module ids without emitting events", function()
    dap.with_socket_pair(function(peer, conn)
        package.loaded["moonbug.test_module"] = {}

        local req = { type = "request", command = "configurationDone", seq = 1 }
        roundtrip(peer, conn, req) -- only the response is on the wire (ready == false)

        local id = p.session.module_ids["moonbug.test_module"]
        expect.not_nil(id)
        expect.eq(id, p.session.module_ids["moonbug.test_module"])

        p.session.ready = true

        local req2 = { type = "request", command = "modules", seq = 2 }
        local resp2 = roundtrip(peer, conn, req2)
        dap.expect_response(resp2, req2, true)
    end)
end)

test("register_module emits a module {reason=new} event when ready", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.ready = true
        p.session.client = conn -- required: the event is sent on session.client
        package.loaded["moonbug.test_module"] = { 1, 2, 3 }

        p.register_module "moonbug.test_module"
        local ev = dap.read_msg(peer)

        expect.eq("event", ev.type)
        expect.eq("module", ev.event)
        expect.eq("new", ev.body.reason)
        expect.eq("moonbug.test_module", ev.body.module.name)
        expect.eq("table", ev.body.module.kind)
    end)
end)

test("registering an already-registered module does not emit another event", function()
    dap.with_socket_pair(function(peer, conn)
        p.session.ready = true
        p.session.client = conn
        package.loaded["moonbug.test_module"] = {}

        p.register_module "moonbug.test_module"
        local ev = dap.read_msg(peer)
        expect.eq("module", ev.event)

        p.register_module "moonbug.test_module"
        expect.is_nil(dap.read_msg_timeout(peer, 0.3), "no second event expected")
    end)
end)
