require "resty.core"
local Monitor = {}
Monitor.default_interval = 1 --second
local monitor_creator = {}
local timers = {}

local function select_peer_generator(monitor, which)
  local peer_selector_key = "::__peer_selector"
  return function(upstream)
    local peers = upstream:get_peers(which)
    if #peers == 0 then
      return nil
    end
    local n = monitor.shared:incr(peer_selector_key, 1)
    n = math.mod(n, #peers)
    return peers[n+1]
  end
end

local function monitor_start_generator(monitor, interval, peer_selector)
  interval = interval or Monitor.default_interval
  local worker_interval = interval * (ngx.worker.count or 1)
  local monitor_check
  local nextpeer = select_peer_generator(monitor, peer_selector)
  local function schedule(self, delay_sec)
    local timer_handle = ngx.timer.at(delay_sec, monitor_check, monitor)
    rawset(timers, self, timer_handle)
  end
  monitor_check = function(self)
    if ngx.worker.exiting then
      return
    end
    local peer = nextpeer(self)
    --TODO: add option to schedule before or after check
    if peer then
      self:check(peer)
    end
    schedule(self, worker_interval)
  end
  return function(self)
    if not timers[self] then
      local offset = (interval / ngx.worker.count) * (ngx.worker.id or (math.random() * ngx.worker.count))
      schedule(self, worker_interval + offset)
    end
  end
end
local function monitor_stop(self)
  --TODO
end


function Monitor.register(name, initializer)
  assert(not monitor_creator[name], "Upstream monitor named \""..name.."\" is already registered")
  if type(initializer) == "table" then
    local metatable = {__index = initializer}
    assert(not initializer.stop and not initializer.start and not initializer.shared, "Monitor \"".. name .. "\" table fields \"start\", \"stop\" and \"shared\" must be nil")
    initializer = function(upstream, ...)
      return setmetatable({}, metatable)
    end
  end
  assert(type(initializer) ~= "function", "Upstream monitor initializer must be a table or function")
  monitor_creator[name]=initializer
end


local shdict_mt = {__index = {}}
do
  local cmds = {
    "get", "get_stale", "incr", "set", "safe_set", "add", "safe_add", "replace", "delete", "ttl", "expire", 
    "lpush", "rpush", "lpop", "rpop"
  }
  for _, v in ipairs(cmds) do
    shdict_mt.__index[v] = function(self, key, ...)
      local shdict = self.shdict[v]
      local shdict_key = self.upstream.keys[("monitor:%s:%s"):format(self.id, key)]
      return shdict[v](shdict, shdict_key, ...)
    end
  end
end

local function Shared(upstream, monitor_id)
  local Upstream = require "durpin.upstream"
  assert(upstream)
  assert(monitor_id)
  return setmetatable({upstream=upstream, shdict=Upstream.get_shdict(), id=monitor_id}, shdict_mt)
end

function Monitor.new(name, upstream, opt)
  local new = assert(monitor_creator[name], "unknown monitor")
  local monitor = new(upstream, opt)
  assert(type(upstream) == "table", "upstream missing?..")
  assert(type(opt) == "table", "opt missing or wrong...")
  assert(opt.id, "opt.id missing")
  if type(monitor) ~= "table" then
    error("Monitor \"".. name .. "\" initialization result must be a table")
  end
  if monitor.stop or monitor.start or monitor.shared then
    error("Monitor \"".. name .. "\" table fields \"start\", \"stop\" and \"shared\" must be nil")
  end
  if type(monitor.check) ~= "function" then
    error("Monitor \"".. name .. "\" table field \"check\" must be a function")
  end
  monitor.start = monitor_start_generator(monitor, opt.interval)
  monitor.stop = monitor_stop
  monitor.shared = Shared(upstream, opt.id)
  return monitor
end

return Monitor
