local ngx_upstream = require "ngx.upstream"
local Upstream = require "durpina.upstream"
Upstream.init("upstream")

local up = Upstream.get("weighted_roundrobin")
up:add_monitor("http-haproxy-agent-check")
up:add_monitor("tcp")
up:add_monitor("http")
up:monitor()
