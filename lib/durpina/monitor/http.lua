local Http = require "resty.http"
local function tcopy(src)
  local dst = {}
  for k, v in pairs(src) do dst[k]=v end
  return dst
end

local function init(upstream, shared, lcl)
  lcl.uri = lcl.uri or "/"
  assert(type(lcl.uri)=="string", "uri must be a string")
  assert(lcl.uri:match("^/"), "uri must start with \"/\"")
  
  lcl.ok_codes = lcl.ok_codes or "101 102 2xx 3xx"
  assert(type(lcl.ok_codes) == "string", "ok_codes must be a string")
  local ok_codes = {}
  for code in lcl.ok_codes:gmatch("([^%s,]+)") do
    local n = tonumber(code:match("^(%d)xx$"))
    if n then
      for i=0, 99 do
        ok_codes[n*100+i]=true
      end
    else
      n = assert(tonumber(code), "invalid ok_code \"" .. code  .. "\"")
      ok_codes[n]=true
    end
  end
  lcl.ok_codes = ok_codes
  
  lcl.request=setmetatable({}, { __mode = 'k' })
  local headers = {}
  --gather all option values starting with "header_" into a headers table
  for k,v in pairs(lcl) do
    local headername = k:match("^header_(,+)")
    if headername then
      headers[headername]=tostring(v)
    end
  end
  lcl.headers = headers
end

local function check_response(response, err, upstream, peer, shared, lcl)
  if err then
    peer:add_fail()
  elseif not lcl.ok_codes[response.code] then
    peer:add_fail()
  elseif peer:is_down() then
    peer:set_up()
  end
end

local function check_generator(response_checker)
  return function(upstream, peer, shared, lcl)
    local request = lcl.request[peer.name]
    if not request then
      request = {
        method = lcl.method or "GET",
        body = lcl.body,
        headers = tcopy(lcl.headers)
      }
      local host = lcl.port and (peer.hostname ..":"..lcl.port) or peer.name
      if host:match(":80$") then
        request.headers.Host = peer.hostname
      else
        request.headers.Host = host
      end
    end
    local address = peer:get_address()
    if not adddress then --peer is unresolved
      return
    end
    local url = ("http://%s:%i%s"):format(address, peer.port, lcl.uri)
    local res, err = Http.new():request_uri(url, request)
    response_checker(res, err, upstream, peer, shared, lcl)
  end
end

local function generate_http_monitor_with_response_handler(handler)
  return {
    init = init,
    check = check_generator(handler),
    with_custom_response_handler = generate_http_monitor_with_response_handler
  }
end

return generate_http_monitor_with_response_handler(check_response)
