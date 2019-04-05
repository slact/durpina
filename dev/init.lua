local Upstream = require "resty/upstream"
local mm = require "mm"
print("heyoo")
print(Upstream.init("upstream"))

local up = Upstream.new("foobar", {
  hosts = {
    { host = "127.0.0.1", port = "8080", weight = 100,       max_fails = 3 },
    { host = "127.0.0.1", port = "8081", weight = 105 }
  }
})
