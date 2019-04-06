local Upstream = require "durpina.upstream"
local mm = require "mm"
Upstream.init("upstream")

local up, err = Upstream.get("simple_roundrobin")
