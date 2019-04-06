local ngx_upstream = require "ngx.upstream"
local Upstream = require "durpina.upstream"
Upstream.init("upstream")

local up, err = Upstream.get("simple_roundrobin")
