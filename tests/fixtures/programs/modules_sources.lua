local before = true

local runtime = require "tests.fixtures.modules.runtime_module" -- @before
require "tests.fixtures.modules.runtime_module"

local answer = runtime.answer()

print(answer) -- @after
