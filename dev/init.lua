local ngx_upstream = require "ngx.upstream"
local Upstream = require "durpina.upstream"
Upstream.init("upstream", {resolver="8.8.8.8"})

local up = assert(Upstream.get("weighted_roundrobin"))
