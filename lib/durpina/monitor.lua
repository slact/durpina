require "resty.core"
local Monitor = {}
Monitor.default_interval = 1 --second
local monitor_check = {}
local monitor_init = {}
local monitor_default_interval = {}

local function table_shallow_copy(tbl)
  local cpy = {}
  for k, v in pairs(tbl) do cpy[k]=v end
  return cpy
end

local function parse_interval(interval)
  local t = type(interval)
  if t == "number" then
    if t == 0 then
      return nil, "interval cannot be 9"
    elseif t < 0 then
      return nil, "interval cannot be negative"
    end
    return t
  elseif t == "string" then
    local mult
    local n, unit = interval:match("^(%d*%.?%d*)%s*(%w*)$")
    if not n then return nil, "invalid interval" end
    n = tonumber(n)
    if not n then return nil, "invalid interval number" end
    if unit == "msec" or unit ==" milliseconds" then
      mult = 0.001
    elseif not unit or unit == "s" or unit == "sec" or unit == "second" or unit == "seconds" then
      mult = 1
    elseif unit == "m" or unit == "min" or unit == "minute" or unit == "minutes" then
      mult = 60
    elseif unit == "h" or unit == "hour" or unit == "hours" then
      mult = 60 * 60
    elseif unit == "d" or unit == "day" or unit == "days" then
      mult = 60 * 60 * 24
    else
      return nil, "invalid interval unit \"" .. unit .. "\""
    end
    return parse_interval(n*mult)
  end
end

local monitor_mt = {__index = {
  nextpeer = function(self)
    local peers = self.upstream:get_peers(self.peer_filter)
    local peercount = #peers
    if peercount == 0 then
      return nil
    end
    
    local n = self.shared:incr(self.peer_selector_key, 1, 0)
    if n > peercount then
      --modulo the shared peer selector counter atomically
      self.shared:incr(self.peer_selector_key, -peercount, n)
    end
    n = n % peercount
    
    return peers[n+1]
  end,
  
  start = function(self)
    self.stopped = nil
    if self.timer then
      return false
    end
    local worker_count = ngx.worker.count()
    local offset = self.interval * (ngx.worker.id() or (math.random() * worker_count))
    return self:schedule(self.worker_interval, offset)
  end,
  
  stop = function(self)
    self.stopped = true
  end,
  
  check = function(self, peer)
    return monitor_check[self.name](self.upstream, peer, self.shared, self.check_state)
  end,
  
  schedule = function(self, interval, offset)
    if self.timer then return end
    local t
    
    local function checkrunner(premature)
      if premature then return end
      if self.stopped or self.still_checking then return end
      local peer = self:nextpeer()
      if peer then
        self.still_checking = true
        self:check(peer)
        self.still_checking = nil
      end
    end
    
    if not offset or offset == 0 then
      t = ngx.timer.every(interval, checkrunner)
    else
      t = ngx.timer.at(offset, function(premature)
        if premature then return end
        checkrunner(premature)
        self.timer = ngx.timer.every(interval, checkrunner)
      end)
    end
    self.timer = t
    return t
  end,
}}


function Monitor.register(name, check)
  local checkpeer, init, interval
  if type(check) == "table" then
    assert(type(check.check)=="function", "Monitor check key must be a function")
    checkpeer = check.check
    if check.init ~= nil then
      assert(type(check.init)=="function", "Monitor init key must be a function")
      init = check.init
    end
    if check.interval ~= nil then
      interval = assert(parse_interval(check.interval))
    end
  else
    checkpeer = check
  end
  assert(not monitor_check[name], "Upstream monitor named \""..name.."\" is already registered")
  assert(type(checkpeer) == "function", "Upstream monitor check function must be... ah... well... a function")
  
  monitor_check[name] = checkpeer
  monitor_init[name] = init
  monitor_default_interval[name]=interval
  return true
end


local shdict_mt = {__index = {}}
do
  local cmds = {
    "get", "get_stale", "incr", "set", "safe_set", "add", "safe_add", "replace", "delete", "ttl", "expire",
    "lpush", "rpush", "lpop", "rpop"
  }
  for _, v in ipairs(cmds) do
    shdict_mt.__index[v] = function(self, key, ...)
      local shdict = self.shdict
      local shdict_key = self.upstream.keys[("monitor:%s:%s"):format(self.id, key)]
      return shdict[v](shdict, shdict_key, ...)
    end
  end
end

local function Shared(upstream, monitor_id)
  local Upstream = require "durpina.upstream"
  assert(upstream)
  assert(monitor_id)
  return setmetatable({upstream=upstream, shdict=Upstream.get_shdict(), id=monitor_id}, shdict_mt)
end

function Monitor.new(name, upstream, opt)
  assert(monitor_check[name], "unknown monitor")
  assert(type(upstream) == "table", "upstream missing?..")
  assert(type(opt) == "table", "opt missing or wrong...")
  opt.interval = opt.interval or monitor_default_interval[name] or Monitor.default_interval
  assert(type(opt.interval) == "number", "monitoring interval must be a number")
  assert(opt.id, "opt.id missing")
  local monitor = {
    name = name,
    id = opt.id,
    interval = opt.interval,
    worker_interval = opt.interval * ngx.worker.count(),
    peer_filter = opt.peers or "all",
    shared = Shared(upstream, opt.id),
    upstream = upstream,
    opt = opt,
    peer_selector_key = "::__peer_selector",
    check_state = table_shallow_copy(opt)
  }
  
  setmetatable(monitor, monitor_mt)
  local init = monitor_init[name]
  if init then
    init(upstream, monitor.shared, monitor.check_state)
  end
  return monitor
end

local included_monitors = {"http", "tcp", "haproxy-agent-check", "http-haproxy-agent-check"}

for _, name in ipairs(included_monitors) do
  Monitor.register(name, require("durpina.monitor."..name))
end

return Monitor
