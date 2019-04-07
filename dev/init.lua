local ngx_upstream = require "ngx.upstream"
local Upstream = require "durpina.upstream"
Upstream.init("upstream")

local up = Upstream.get("weighted_roundrobin")
up:add_monitor("dummy", {})
up:monitor()
