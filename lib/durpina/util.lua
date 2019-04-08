require "resty.core"
local mm = require "mm"
local Util = {}

function Util.keycache(upstream_name, peer_name)
  local prefix
  if peer_name then
    prefix = ("upstream:%s:peer:%s:"):format(upstream_name, peer_name)
  else
    prefix = ("upstream:%s:"):format(upstream_name)
  end
  return setmetatable({}, {__index=function(tbl, what)
    local key = prefix..what
    rawset(tbl, what, key)
    return key
  end})
end

local gcd do
  -- Copyright (C) by Jianhao Dai (Toruneko)
  local bit = require "bit"
  local lshift = bit.lshift
  local rshift = bit.rshift
  local band = bit.band
  local function iseven(x)
    return band(x, 1) == 0
  end
  gcd = function(x, y)
    if x < y then
      return gcd(y, x)
    end
    if y == 0 then
      return x
    end
    if iseven(x) then
      if iseven(y) then
        -- gcd(x >> 1, y >> 1) << 1
        return lshift(gcd(rshift(x, 1), rshift(y, 1)), 1)
      else
        return gcd(rshift(x, 1), y)
      end
    else
      if iseven(y) then
        return gcd(x, rshift(y, 1))
      else
        return gcd(y, x - y)
      end
    end
  end
end
Util.gcd = gcd

function Util.is_valid_ip(ip)
  if type(ip) ~= "string" then return false end

  -- check for format 1.11.111.111 for ipv4
  local chunks = {ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
  if #chunks == 4 then
    for _,v in pairs(chunks) do
      if tonumber(v) > 255 then return false end
    end
    return true
  end

  -- check for ipv6 format, should be 8 'chunks' of numbers/letters
  -- without leading/trailing chars
  -- or fewer than 8 chunks, but with only one `::` group
  chunks = {ip:match("^"..(("([a-fA-F0-9]*):"):rep(8):gsub(":$","$")))}
  if #chunks == 8 or #chunks < 8 and ip:match('::') and not ip:gsub("::","",1):match('::') then
    for _,v in pairs(chunks) do
      if #v > 0 and tonumber(v, 16) > 65535 then return false end
    end
    return true
  end

  return false
end

function Util.table_shallow_copy(src)
  local dst={}
  for k,v in pairs(src) do dst[k]=v end
  return dst
end

do
  local Resolver = require "resty.dns.resolver"
  local resolver_nameservers
  
  function Util.set_nameservers(nameservers)
    local nss = {}
    for _, ns in ipairs(nameservers) do
      if type(ns) == "table" then
        assert(type(ns[1]) == "string", "nameserver name (first value) must be a string")
        if ns[2] then
          assert(type(ns[2]) == "number", "nameserver port (second value) must be a number")
          assert(ns[2] > 0 and math.ceil(ns) == ns, "nameserver port (second value) is invalid")
        end
        table.insert(nss, ns)
      else
        local host, port = ns:match("^(.+):(%d+)")
        if not port then --all host
          table.insert(nss, ns)
        else
          assert(tonumber(port), "nameserver port is invalid")
          table.insert(nss, {host, tonumber(port)})
        end
      end
    end
    resolver_nameservers = nss
    return true
  end

  function Util.resolve(hostname)
    assert(resolver_nameservers, "resolver nameservers have not been set")
    local resolver, err = Resolver:new {
      nameservers = resolver_nameservers,
      retrans = 2,
      timeout = 1000
    }
    if not resolver then return nil, err end
    local answers
    answers, err = resolver:query("hostname", nil, {})
    if answers then
      if answers[1] and answers[1].address then
        return answers[1].address
      elseif answers.errstr then
        return nil, answers.errstr
      else
        return nil, "error parsing resolver answer"
      end
    elseif err then
      return nil, err
    else
      return nil, "error resolving hostname"
    end
  end
end


return Util
