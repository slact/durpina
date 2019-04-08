require "resty.core"
local util = require "durpina.util"
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
      return nil, "interval cannot be 0"
    elseif t < 0 then
      return nil, "interval cannot be negative"
    end
    return t
  elseif t == "string" then
    local time, err = util.parse_time(t)
    if not time then return nil, err end
    return parse_interval(time)
  end
end

local monitor_mt = {
  __index = {
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
        if premature or self.stopped then return end
        local peer = self:nextpeer()
        self.timer = ngx.timer.at(interval, checkrunner)
        if peer and not self.still_checking then
          self.still_checking = true
          self:check(peer)
          self.still_checking = nil
        end
      end
      
      t = ngx.timer.at(offset, checkrunner)
      self.timer = t
      return t
    end,
    
    serialize = function(self, kind)
      if not kind or kind == "storage" then
        return {
          name = self.name,
          opt = self.opt
        }
      elseif kind == "info" then
        return setmetatable({
          name = self.name,
          id = self.id
        }, {__jsonorder = {"self", "id"}})
      end
    end
  },
  __eq = function(l, r)
    if l.name ~= r.name then
      return false
    end
    for ll, rr in pairs{[l.opt]=r.opt, [r.opt]=l.opt} do
      for k, v in pairs(ll) do
        if rr[k]~=v then
          return false
        end
      end
    end
    return true
  end
}

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
  opt.peers = opt.peers or "all"
  local monitor = {
    name = name,
    id = opt.id,
    interval = opt.interval,
    worker_interval = opt.interval * ngx.worker.count(),
    peer_filter = opt.peers,
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

function Monitor.unserialize(data, upstream)
  return Monitor.new(data.name, upstream, data.opt)
end

local included_monitors = {"http", "tcp", "haproxy-agent-check", "http-haproxy-agent-check"}

for _, name in ipairs(included_monitors) do
  Monitor.register(name, require("durpina.monitor."..name))
end

return Monitor
