local tcp_monitor = require "durpina.monitor.tcp"

local function handle_agent_check_data(str, upstream, peer, shared, lcl)
  local percent = tonumber(str:match("(%d+)%%"))
  if percent then
    peer:set_weight(peer.initial_weight * (percent / 100))
  end
  if str:match("up") or str:match("ready") then
    if peer:is_down() then
      peer:set_state("up")
    end
  elseif str:match("maint") then
    peer:set_state("down")
  elseif str:match("down") or str:match("failed") or str:match("stopped") then
    peer:set_state("down")
  end
end

local haproxy_agent_check_monitor = tcp_monitor.with_custom_response_handler(function(response, err, upstream, peer, shared, lcl)
  if err then
    peer:add_fail()
  else
    handle_agent_check_data(response, upstream, peer, shared, lcl)
  end
end)

haproxy_agent_check_monitor.handle_agent_check_data = handle_agent_check_data

return haproxy_agent_check_monitor
