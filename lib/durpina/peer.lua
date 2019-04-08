require "resty.core"
local Upstream = require "durpina.upstream"
local util = require "durpina.util"
local shdict = nil

local Peer = {
  default_port = 80,
  set_shdict = function(sh)
    shdict = sh
  end
}

local function try_resolve(peer, force)
  local addr = util.resolve(peer.hostname)
  if addr then
    if force then
      shdict:set(peer.keys.address, addr)
    else
      shdict:safe_set(peer.keys.address, addr)
    end
  end
end

local peer_meta = {
  __index= {
    init = function(self, oldpeer)
      assert(not self.initialized)
      if self.default_down and not oldpeer then
        self:set_state("down")
      end
      
        if self.weight then
        self:set_weight(self.weight, true)
        self.initial_weight = self.weight
        self.weight = nil
      elseif self.initial_weight then
        local new_weight = self.initial_weight
        if oldpeer and oldpeer.initial_weight ~= self.initial_weight then
          --use the current weight as a scaling factor for new weight
          local oldweight = oldpeer:get_weight()
          new_weight = math.ceil(oldweight/oldweight.initial_weight) * self.initial_weight
        end
        if not shdict:get(self.keys.weight) then
          self:set_weight(new_weight, true)
        end
      end
      self.initialized = true
      self:resolve() --resolve if necessary
      return self
    end,
    remove = function(self)
      for k, _ in pairs(self.keys) do
        shdict:expire(k, 1)
      end
      return true
    end,
    resolve = function(self, force_overwrite)
      if not force_overwrite and shdict:get(self.keys.address) then
        --already resolved
        return true
      end
      
      local current_address = shdict:get(self.keys.address)
      if not current_address and self.initial_address then
        return shdict:safe_set(self.keys.address, self.initial_address)
      end
      
      local ok, err = pcall(try_resolve, self, force_overwrite)
      if not ok then
        if err:match("API disabled") then
          ngx.timer.at(0, function(premature)
            if premature then return end
            try_resolve(self, force_overwrite)
          end)
        else
          error(err)
        end
      end
    end,
    get_address = function(self)
      return shdict:get(self.keys.address)
    end,
    get_weight = function(self)
      local weight = shdict:get(self.keys.weight)
      if weight ~= rawget(self, "current_weight") then
        rawset(self, "current_weight", weight)
        self:get_upstream():calculate_weights()
      end
      return weight
    end,
    set_weight = function(self, weight, skip_upstream_recalculate)
      local upstream = self:get_upstream()
      shdict:set(self.keys.weight, weight)
      if upstream then
        shdict:incr(upstream.keys.weights_revision, 1, 0)
        if not skip_upstream_recalculate and self.current_weight ~= weight then
          upstream:calculate_weights()
        end
      end
      self.current_weight = weight
      return weight
    end,
    get_upstream = function(self)
      return Upstream.get(self.upstream_name, true, true)
    end,
    set_state = function(self, state)
      if state == "up" then
        shdict:delete(self.keys.down)
        shdict:delete(self.keys.temp_down)
        shdict:delete(self.keys.fail)
      elseif state == "down" then
        shdict:set(self.keys.down, true)
      elseif state == "temporary_down" then
        shdict:set(self.keys.temp_down, true, self.fail_timeout)
      else
        error("setting unoknown peer state " .. state or "?")
      end
      return true
    end,
    is_down = function(self, kind)
      if kind == nil or kind == "any" then
        return (shdict:get(self.keys.down) or shdict:get(self.keys.temp_down)) and true
      elseif kind == "down" or kind == "permanent" then
        return shdict:get(self.keys.down) and true
      elseif kind == "temp_down" or kind == "temporary" or kind == "failed" then
        return shdict:get(self.keys.temp_down) and true
      end
      return false
    end,
    is_failing = function(self)
      return shdict:get(self.keys.fail) ~= nil
    end,
    add_fail = function(self)
      local key = self.keys.fail
      local newval, err = shdict:incr(key, 1)
      if not newval then
        -- possible race condition here, but shdict has no set_expire(),
        -- nor can expire time be set in incr(), so we're stuck with this.
        if err == "not found" or err == "not a number" then
          return shdict:set(key, 1, self.fail_timeout) and 1 or 0
        end
        return 0
      end
      if self.max_fails > 0 and newval > self.max_fails then
        self:set_state("temporary_down")
      end
      return newval
    end,
    serialize = function(self, kind)
      local ser
      if not kind or kind == "storage" then
        ser = util.table_shallow_copy(self)
        ser.keys = nil
        ser.initialized = nil
      elseif kind == "info" then
        local state
        if self:is_down("permanent") then
          state = "down"
        elseif self:is_down("temporary") then
          state = "temp_down"
        elseif self:is_failing() then
          state = "failing"
        else
          state = "up"
        end
        ser = setmetatable({
          name = self.name,
          address = self:get_address() or "?",
          weight = self:get_weight() or "?",
          state = state
        }, {__jsonorder = {"name", "address", "weight", "state"}})
      end
      return ser
    end,
  },
  __tostring = function(self)
    return ("%s weight=%s{%s} fails={%s} %s"):format(self.name, tostring(self.current_weight), tostring(self:get_weight()), tostring(shdict:get(self.keys.fail)), (self:is_down() and "{down}" or ""))
  end
}

function Peer.unserialize(data)
  return Peer.new(data, data.upstream_name)
end

function Peer.new(srv, upstream_name, peer_number)
  srv.port = tonumber(srv.port) or Peer.default_port
  if not srv.name and srv.address then
    srv.name = ("%s:%i"):format(srv.address, srv.port)
  end
  if srv.host and not srv.hostname then
    srv.hostname = srv.host
  end
  if not srv.name and srv.hostname then
    srv.name = ("%s:%i"):format(srv.hostname, srv.port)
  end
  if not srv.name and srv.address then
    srv.name = ("%s:%i"):format(srv.address, srv.port)
  end
  if not srv.name then
    return nil, "upstream \"" .. upstream_name.."\" server " ..  (peer_number or "") ..  " name missing"
  end

  local weight = srv.initial_weight or 1
  if weight ~= math.ceil(weight) or weight < 1 then
    return nil, "upstream server named \""..srv.name.."\" has invalid weight " .. tostring(weight)
  end
  if srv.address and not util.is_valid_ip(srv.address) then
    return nil, "upstream server named \""..srv.name.."\" has invalid address " .. tostring(srv.address)
  end

  local peer = {
    name = srv.name,
    hostname = srv.hostname or srv.name:match("^[^:]*"),
    initial_address = srv.address or srv.initial_address,
    port = tonumber(srv.port) or 80,
    default_down = srv.default_down,
    initial_weight = tonumber(srv.initial_weight) or 1,
    max_fails = tonumber(srv.max_fails) or 3,
    fail_timeout = tonumber(srv.fail_timeout) or 10,
    keys = util.keycache(upstream_name, srv.name),
    upstream_name = upstream_name
  }
  setmetatable(peer, peer_meta)
  return peer
end

return Peer
