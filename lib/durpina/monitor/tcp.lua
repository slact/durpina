require "resty.core"
local function init(upstream, shared, lcl)
  if lcl.timeout ~= nil then
    assert(type(lcl.timeout) == "number", "timeout must be a number")
  end
end

local function check_response(response, err, upstream, peer, shared, lcl)
  if err then
    peer:add_fail()
    --print("" .. err .. "; couldn't read line -- it seems to be failing")
  end
end

local function check_generator(response_checker)
  return function(upstream, peer, shared, lcl)
    local address = peer:get_address()
    if not address then --skip check, we don't know this peer's address
      return
    end
    local socket = ngx.socket.tcp()
    if lcl.timeout then
      socket:settimeout(lcl.timeout)
    end
    local res, err = socket:connect(address, lcl.port or peer.port)
    if not res then
      response_checker(nil, err or "failed", upstream, peer, shared, lcl)
    else
      res, err = socket:receive(lcl.receive or "*l")
      response_checker(res, err, upstream, peer, shared, lcl)
      socket:close()
    end
  end
end

local function generate_tcp_monitor_with_response_handler(handler)
  return {
    init = init,
    check = check_generator(handler),
    with_custom_response_handler = generate_tcp_monitor_with_response_handler
  }
end

return generate_tcp_monitor_with_response_handler(check_response)
