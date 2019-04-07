require "resty.core"
local Monitor = {}
Monitor.default_interval = 1 --second
local monitor_check = {}
local monitor_default_interval = {}

local mm = require "mm"

local monitor_mt = {__index = {
  nextpeer = function(self)
    local peers = self.upstream:get_peers(self.peer_filter)
    if #peers == 0 then
      return nil
    end
    
    local n = self.shared:incr(peer_selector_key, 1, 0)
    n = n % #peers
    return peers[n+1]
  end,
  
  start = function(self)
    if self.timer then
      return false
    end
    local worker_count = ngx.worker.count()
    local offset = self.interval * (ngx.worker.id() or (math.random() * worker_count))
    mm(offset)
    return self:schedule(self.worker_interval, offset)
  end,
  
  stop = function(self)
    error(":not implemented yet")
  end,
  
  check = function(self, peer)
    return monitor_check[self.name](self.upstream, peer, self.shared, self.check_state)
  end,
  
  schedule = function(self, interval, offset)
    local t
    if not offset or offset == 0 then
      t = ngx.timer.every(interval, function(premature)
        if premature then return end
        if self.still_checking then return end
        local peer = self:nextpeer()
        if peer then
          self.still_checking = true
          self:check(peer)
          self.still_checking = nil
        end
      end)
    else
      t = ngx.timer.at(offset, function(premature)
        if premature then return end
        self:schedule(interval, 0)
      end)
    end
    self.timer = t
    return t
  end,
}}


function Monitor.register(name, checkpeer)
  assert(not monitor_check[name], "Upstream monitor named \""..name.."\" is already registered")
  assert(type(checkpeer) == "function", "Upstream monitor checkpeer parameter must be a function")
  monitor_check[name] = checkpeer
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
    check_state = {}
  }
  for k, v in pairs(opt) do
    monitor.check_state[k]=v
  end
  
  setmetatable(monitor, monitor_mt)
  
  return monitor
end

Monitor.register("http", function(upstream, peer, shared, lcl)
  local req_str = lcl.request
  if not lcl.request then
    lcl.request = 
  end
  
  
end)

return Monitor
