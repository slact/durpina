local shdict --dictionary shared between processes

local upstreams = {}
local util = require "durpina.util"
local cjson = require "cjson"
local ngx_upstream = require "ngx.upstream"
local Upstream = {}
local Peer --don't set it yet, this will lead to a cyclic dependency
local Monitor -- same deal
local mm = require "mm"
local DKJson = require "durpina.dkjson"

function Upstream.init(shared_dict_name, config)
  Peer = require "durpina.peer"
  Monitor = require "durpina.monitor"
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
    serialize = function(self, kind)
      local peers = {}
      for _, peer in ipairs(self.peers) do
        table.insert(peers, peer:serialize(kind))
      end
      local monitors = {}
      for _, mon in ipairs(self.monitors or {}) do
        table.insert(monitors, mon:serialize(kind))
      end
      local ser
      if not kind or kind == "storange" then
        ser= {
          name = self.name,
          peers = peers,
          monitors = monitors
        }
      elseif kind == "info" then
        ser= setmetatable({
          name = self.name,
          revision = self.revision,
          peers = peers,
          monitors = monitors
        }, {__jsonorder={"name", "revision", "peers", "monitors"}})
      end
      return ser
    end,
    info = function(self)
      local info = self:serialize("info")
      return DKJson.encode(info, {indent=true})
    end,
    revise = function(self)
      mm("revise " .. self.name)
      self.revision = self.revision + 1
      local serialized = cjson.encode(self:serialize())
      local shared_serialized = shdict:get(self.keys.serialized)
      local shrev = shdict:get(self.keys.revision) or 0
      if shrev > self.revision then
        self.revision = self.revision - 1
        return nil, "upstream update failed due to a cuncurrent update. please try again"
      end
      if shared_serialized ~= serialized then
        mm("write it!")
        shdict:set(self.keys.serialized, serialized)
        self.revision = shdict:incr(self.keys.revision, 1, 0)
      end
      return true
    end,
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
    add_peer = function(self, peerdata)
      if type(peerdata) == "string" then
        peerdata = {
          name = peerdata:match("^%s*([^%s])"),
          weight = tonumber(peerdata:match("weight=(%d+)")),
          max_fails = tonumber(peerdata:match("max_fails=(%d+)")),
          fail_timeout = peerdata:match("fail_timeout=(%d)"),
          down = peerdata:match("%sdown") and true or nil
        }
      end
      if type(peerdata) ~= "table" then
        return nil, "peerdata must be a table or string"
      end
      peerdata.weight = tonumber(peerdata.weight)
      if peerdata.fail_timeout then
        local t, err = util.parse_time(peerdata.fail_timeout)
        if not t then return nil, err end
        peerdata.fail_timeout = t
      end
      
      local newpeer = Peer.new(peerdata, self.name)
      
      if self:get_peer(newpeer.name) then
        return nil, "peer named \""..newpeer.name.."\" already exists"
      end
      
      table.insert(self.peers, newpeer)
      newpeer:init()
      return self:revise()
    end,
    remove_peer = function(self, peer)
      if peer.upstream_name ~= self.name or self:get_peer(peer.name) ~= peer then
        return nil, "peer isn't part of this upstream"
      end
      
      for i, p in ipairs(self.peers) do
        if p == peer then
          table.remove(self.peers, i)
          peer:remove()
        end
      end
      self:revise()
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
      local monitor = assert(require("durpina.monitor").new(name, self, opt))
      for _, m in pairs(self.monitors) do
        if m.opt.id == opt.id then
          if m == monitor then
            return nil, "same monitor being added, that's ok"
          else
            error("monitor with id \"" .. opt.id.."\" already exists for upstream \"" .. self.name .."\"")
          end
        end
      end
      
      opt.peers = opt.peers or "all"
      assert(opt.peers == "all", "can only monitor all peers for now")
      
      table.insert(self.monitors, monitor)
      monitor:start()
      return self:revise()
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
    end,
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
local mm = require "mm"

local function Upstream_update_local(upstream_name, servers, opt)
  if not servers then
    return fail_warn("no servers for upstream " .. upstream_name)
  end
  
  local oldup = upstreams[upstream_name]
  
  if opt and oldup and oldup.revision >= (opt.revision or 0) then
    --what we have already is newer
    return oldup
  end
  
  local unique_upstream_peers = {}
  local upstream_peers_array = {}
  for i, srv in ipairs(servers) do
    local peer, err = Peer.new(srv, upstream_name, i)
    if not peer then return fail_warn(err) end
    
    local oldpeer = oldup and oldup:get_peer(peer.name)
    peer:init(oldpeer)
    
    if unique_upstream_peers[peer.name] then
      return fail_warn("upstream \"" .. upstream_name.."\" server named \""..srv.name.."\" already exists")
    end
    
    unique_upstream_peers[peer.name] = peer
    table.insert(upstream_peers_array, peer)
  end
  
  local upstream = {
    name = upstream_name,
    cp = 1, -- current peer index
    peers = upstream_peers_array, -- peers
    monitors = {},
    keys = util.keycache(upstream_name),
    revision = opt.revision or 0,
  }
  
  setmetatable(upstream, upstream_meta)
  upstreams[upstream_name] = upstream
  
  for _, mon in ipairs(opt and opt.monitors or {}) do
    table.insert(upstream.monitors, Monitor.unserialize(mon, upstream))
  end
  if oldup then --stop old monitors
    oldup:unmonitor()
  end
  
  upstream:calculate_weights()
  upstream:monitor()
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
  local up, err = Upstream_update_local(upstream_name, servers, {revision=1})
  if not up then return nil, err end
  up:revise()
  return up
end

function Upstream.get(upstream_name, nowrap, noupdate)
  local upstream = upstreams[upstream_name]
  if not noupdate then
    local keys = upstream and upstream.keys or util.keycache(upstream_name)
    local shared_revision = shdict:get(keys.revision) or 0
    if (upstream and upstream.revision or 0) < shared_revision then
      mm("revision: "..(upstream and upstream.revision or "-") .. "{"..(shared_revision or 0).."}")
      
      local data = shdict:get(keys.serialized)
      data = cjson.decode(data)
      data.revision = shared_revision
      Upstream.unserialize(data)
      upstream = upstreams[upstream_name]
    end
  end
  if not upstream and not nowrap then
     wrap(upstream_name)
     upstream = upstreams[upstream_name]
  end
  if not upstream then return nil, "unknown upstream ".. upstream_name end
  return upstream
end

function Upstream.unserialize(data)
  mm("unserialize upstream " .. data.name or "?")
  return Upstream_update_local(data.name, data.peers, data)
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
