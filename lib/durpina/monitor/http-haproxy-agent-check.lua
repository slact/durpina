local tcp_agent_check_monitor = require "durpina.monitor.haproxy-agent-check"
local handle_agent_check_data = tcp_agent_check_monitor.handle_agent_check_data

local http_agent = require "durpina.monitor.http"

local function check_response(response, err, upstream, peer, shared, lcl)
  if err or response.status >= 400 then
    peer:add_fail()
  else
    response:read_body()
    handle_agent_check_data(response.body, upstream, peer, shared, lcl)
  end
end

return http_agent.with_custom_response_handler(check_response)
