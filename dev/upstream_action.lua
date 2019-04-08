local cjson = require "cjson"
local Upstream = require "durpina.upstream"
local action = ngx.var[2]
local up, err = Upstream.get(ngx.var[1])
if not up then
  ngx.status = 404
  return ngx.say("upstream not found; " .. err or "")
end

local data
local method = ngx.req.get_method()
if method == "POST" then
  ngx.req.read_body()
  local data_in = ngx.req.get_body_data() or ""
  local ok
  ok, data = pcall(cjson.decode, data_in)
  if not ok then
    ngx.status = 400
    return ngx.say("Error parsing JSON data: " .. data)
  end
else
  data = nil
end
if action == "info" then
  ngx.header.content_type = "text/json"
  ngx.say(up:info())
elseif action == "set_peer_weights" then 
  for peername, weight in pairs(data) do
    local peer = up:get_peer(peername)
    if not peer then 
      ngx.status = 404
      return ngx.say("peer " .. peername .." not found in upstream " .. up.name)
    end
    peer:set_weight(weight)
  end
  print(tostring(up))
  return ngx.say(tostring(up))
else
  local ok, err
  if action == "add_peer" then
    ok, err = up:add_peer(data)
  elseif action == "remove_peer" then
    ok, err = up:add_peer(data)
  elseif action == "add_monitor" then
    ok, err = up:add_monitor(data.name, data)
  elseif action == "remove_monitor" then
    ok, err = up:remove_monitor(data.name, data)
  else
    ok, err = nil, "unknown action " .. action
  end
  if not ok then
    ngx.status = 400
    print(err)
    return ngx.say(err)
  end
  ngx.say("ok")
end
