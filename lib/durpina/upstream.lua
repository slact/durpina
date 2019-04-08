local shdict --dictionary shared between processes

local upstreams = {}
local util = require "durpina.util"
local cjson = require "cjson"
local ngx_upstream = require "ngx.upstream"
local Upstream = {}
local Peer --don't set it yet, this will lead to a cyclic dependency

function Upstream.init(shared_dict_name, config)
  Peer = require "durpina.peer"
  local shared_dict = ngx.shared[shared_dict_name]
  if not shared_dict then
    error("no shared dictionary named \"" .. shared_dict_name.."\"")
  end
  config = config or {}
  if config.default_port then 
    assert(type(config.default_port) == "number", "default_port must be a number")
    Peer.default_port = config.default_port
  end
  if config.resolver then
    Upstream.set_resolver(config.resolver)
  end
  shdict = shared_dict
  
  Peer.set_shdict(shdict)
  return true
end

function Upstream.set_resolver(resolver)
  if type(resolver) == "string" then
    return util.set_nameservers({resolver})
  elseif type(resolver) == "table" then
    return util.set_nameservers({resolver})
  else
    error("resolver must be a string or table")
  end
  return true
end

local upstream_meta = {
  __index={
    calculate_weights = function(self)
      local gcd, max = 0, 0
      for _, peer in pairs(self.peers) do
        local weight = peer:get_weight()
        gcd = util.gcd(weight, gcd)
        max = math.max(max, weight)
      end
      self.gcd = gcd
      self.max = max
      return true
    end,
    get_weight_calcs = function(self)
      local shared_weights_revision = shdict:get(self.keys.weights_revision)
      if self.weights_revision ~= shared_weights_revision then
        self.weights_revision = shared_weights_revision
        self:calculate_weights()
      end
      return self.max, self.gcd
    end,
    get_peer = function(self, peer_name)
      for _, peer in pairs(self.peers) do
        if peer.name == peer_name then
          return peer
        end
      end
    end,
    get_peers = function(self, selector)
      if selector == "all" or selector == nil then
        return util.table_shallow_copy(self.peers)
      else
        local peers = {}
        local fn, param
        if selector == "failing" then
          fn = "is_failing"
        elseif selector == "temporary_down" then
          fn, param = "is_down", "temporary"
        elseif selector == "permanent_down" then
          fn, param = "is_down", "permanent"
        elseif selector == "down" then
          fn, param = "is_down", "any"
        end
        for _, peer in ipairs(self.peers) do
          if peer[fn](peer, param) then
            table.insert(peers, peer)
          end
        end
        return peers
      end
    end,
    --monitoring
    add_monitor = function(self, name, opt)
      opt = opt or {}
      for k,v in pairs(opt) do
        assert(type(k)=="string", "only string keys are allowed for Monitor options")
        assert(type(v)=="string" or type(v)=="number", "only string and number values are allowed for Monitor options")
      end
      opt.id = opt.id or name
      if self.monitors[opt.id] then
        error("monitor with id \"" .. opt.id.."\" already exists for upstream \"" .. self.name .."\"")
      end
      local monitor = assert(require("durpina.monitor").new(name, self, opt))
      
      opt.peers = opt.peers or "all"
      assert(opt.peers == "all", "can only monitor all peers for now")
      
      self.monitors[opt.id]=monitor
      return true
    end,
    monitor = function(self)
      for _, monitor in pairs(self.monitors) do
        monitor:start()
      end
      return true
    end,
    unmonitor = function(self)
      for _, monitor in pairs(self.monitors) do
        monitor:stop()
      end
      return true
    end
    
  },
  __tostring = function(self)
    local max, gcd = self:get_weight_calcs()
    local header = ("%s gcd={%s} max={%s} rev=%s{%s} weights_rev=%s{%s}"):format(self.name, tostring(gcd), tostring(max), tostring(self.revision), tostring(shdict:get(self.keys.revision)), tostring(self.weights_revision), tostring(shdict:get(self.keys.weights_revision)))
    local peerstr = {}
    for _, peer in pairs(self.peers) do
      table.insert(peerstr, "  - " .. tostring(peer))
    end
    table.sort(peerstr)
    local str = header .."\n"..table.concat(peerstr, "\n")
    return str
  end
}

local function fail_warn(msg)
  ngx.log(ngx.WARN, msg)
  return nil, msg
end

local function Upstream_update(upstream_name, servers, opt)
  local version = opt and tonumber(opt.version or 0)
  if not servers then
    return fail_warn("no servers for upstream " .. upstream_name)
  end
  
  local oldup = upstreams[upstream_name]
  local unique_upstream_peers = { }
  local upstream_peers_array = {}
  for i, srv in ipairs(servers) do
    local peer, err = Peer.new(srv, upstream_name, i)
    if not peer then return fail_warn(err) end
    
    local oldpeer = oldup and oldup:get_peer(peer.name)
    peer:initialize(oldpeer)
    
    if unique_upstream_peers[peer.name] then
      return fail_warn("upstream \"" .. upstream_name.."\" server named \""..srv.name.."\" already exists")
    end
    
    unique_upstream_peers[peer.name] = peer
    table.insert(upstream_peers_array, peer)
  end
  local upstream = {
    name = upstream_name,
    version = version,
    cp = 1, -- current peer index
    peers = upstream_peers_array, -- peers
    keys = util.keycache(upstream_name),
    revision = opt.revision or 0,
    monitors = {}
  }
  
  setmetatable(upstream, upstream_meta)
  local serialized = cjson.encode(upstream)
  local shared_serialized = shdict:get(upstream.keys.serialized)
  local shared_revision = shdict:get(upstream.keys.revision) or 0
  if shared_serialized ~= serialized then
    if (shared_revision or 0) <= (upstream.revision or 0) then
    shdict:set(upstream.keys.serialized, serialized)
    end
    if opt and not opt.no_revision_update then
      upstream.revision = shdict:incr(upstream.keys.revision, 1, 0)
    end
  end
  
  upstreams[upstream_name] = upstream
  upstream:calculate_weights()
  return upstream
end

local function wrap(upstream_name)
  local upstream_servers = ngx_upstream.get_servers(upstream_name)
  if not upstream_servers then return nil, "no such upstream" end
  local servers = {}
  for _, s in ipairs(upstream_servers) do
    if not s.backup and s.address ~= "0.0.0.0" and s.address ~="0.0.0.1" then
      local address, port = s.addr:match("^(.+):(%d+)")
      table.insert(servers, {
        name = s.name,
        address = address,
        port = tonumber(port),
        fail_timeout = s.fail_timeout,
        max_fails = s.max_fails,
        initial_weight = s.weight,
        default_down = s.down
      })
    end
  end
  return Upstream_update(upstream_name, servers, {version=1})
end

function Upstream.get(upstream_name, nowrap, noupdate)
  local upstream = upstreams[upstream_name] or (not nowrap and wrap(upstream_name))
  if not upstream then return nil, "unknown upstream ".. upstream_name end
  if not noupdate then
    local shared_revision = shdict:get(upstream.keys.revision)
    if upstream.revision ~= shared_revision then
      --another worker must have changed the upstream. rebuild it.
      local data = shdict:get(upstream.keys.serialized)
      data = cjson.decode(data)
      Upstream_update(upstream_name, data.peers, data)
      upstream = upstreams[upstream_name]
    end
  end
  return upstream
end

function Upstream.get_all()
  local ups = {}
  for name, _ in pairs(upstreams) do
    table.insert(ups, Upstream.get(name))
  end
  return ups
end

function Upstream.get_shdict()
  return shdict
end

return Upstream
