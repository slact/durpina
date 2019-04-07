-- Copyright (C) by Jianhao Dai (Toruneko)
local shdict --dictionary shared between processes
local shdict_name
local upstreams = {}
local cjson = require "cjson"
local ngx_upstream = require "ngx.upstream"
local ngx_balancer = require "ngx.balancer"
local math_gcd = require "durpina.gcd"
local rawget = rawget
local Upstream = {}

local peer_meta = {
    __index= {
        get_weight = function(self)
            local weight = shdict:get(self.keys.weight)
            if weight ~= rawget(self, "current_weight") then
                rawset(self, "current_weight", weight)
                self:get_upstream():calculate_weights()
            end
            return weight
        end,
        set_weight = function(self, weight, skip_upstream_recalculate)
            if not self.current_weight and shdict:get(self.keys.weight)~= nil and (shdict:get(self.keys.weight) ~= weight) then
                error("bah!")
            end
                
            
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
            return upstreams[self.upstream_name]
        end,
        set_down = function(self)
            return shdict:set(self.keys.down, true)
        end,
        set_temporary_down = function(self)
            return shdict:set(self.keys.temp_down, true, self.fail_timeout)
        end,
        is_down = function(self)
            if shdict:get(self.keys.down) or shdict:get(self.keys.temp_down) then
                return true
            end
            return false
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
                self:set_temporary_down()
            end
            return newval
        end,
    },
    __tostring = function(self)
        return ("%s weight=%s{%s} fails={%s} %s"):format(self.name, tostring(self.current_weight), tostring(self:get_weight()), tostring(shdict:get(self.keys.fail)), (self:is_down() and "{down}" or ""))
    end
}

local upstream_meta = {
    __index={
        calculate_weights = function(self)
            local gcd, max = 0, 0
            for _, peer in pairs(self.peers) do
                local weight = peer:get_weight()
                gcd = math_gcd(weight, gcd)
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

local function keycache(upstream_name, peer_name)
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

function Upstream.init(shared_dict_name, config)
    local shared_dict = ngx.shared[shared_dict_name]
    if not shared_dict then
        error("no shared dictionary named \"" .. shared_dict_name.."\"")
    end
    config = config or {}
    Upstream.default_port = config.default_port or 8080
    shdict = shared_dict
    shdict_name = shared_dict_name
    return true
end

local function fail_warn(msg)
    ngx.log(ngx.WARN, msg)
    return nil, msg
end

function Upstream.update(upstream_name, servers, opt)
    local version = opt and tonumber(opt.version or 0)
    if not servers then
        return fail_warn("no servers for upstream " .. upstream_name)
    end
    local oldup = upstreams[upstream_name]
    local unique_upstream_peers = { }
    local upstream_peers_array = {}
    for i, srv in ipairs(servers) do
        srv.port = tonumber(srv.port) or Upstream.default_port
        if not srv.name and srv.address then
            srv.name = ("%s:%i"):format(srv.address, srv.port)
        end
        if not srv.name or not srv.address then
            return fail_warn("server ".. i .. "name or address missing in upstream" .. upstream_name)
        end

        if unique_upstream_peers[srv.name] then
            return fail_warn("upstream server named \""..srv.name.."\" already exists in upstream " .. upstream_name)
        end
        local weight = srv.initial_weight or 1
        if weight ~= math.ceil(weight) or weight < 1 then
            return fail_warn("upstream server named \""..srv.name.."\" has invalid weight " .. weight)
        end
        local peer = {
            name = srv.name,
            address = srv.address,
            default_down = srv.default_down,
            port = tonumber(srv.port) or 8080,
            initial_weight = tonumber(srv.initial_weight) or 1,
            max_fails = tonumber(srv.max_fails) or 3,
            fail_timeout = tonumber(srv.fail_timeout) or 10,
            keys = keycache(upstream_name, srv.name),
            upstream_name = upstream_name
        }
        setmetatable(peer, peer_meta)
        local oldpeer = oldup and oldup:get_peer(peer.name)
        if peer.default_down and not oldpeer then
            peer:set_down()
        end
        
        if peer.weight then
            peer:set_weight(peer.weight, true)
            peer.initial_weight = peer.weight
            peer.weight = nil
        elseif peer.initial_weight then
            local new_weight = peer.initial_weight
            if oldpeer and oldpeer.initial_weight ~= peer.initial_weight then
                --use the current weight as a scaling factor for new weight
                local oldweight = oldpeer:get_weight()
                new_weight = math.ceil(oldweight/oldweight.initial_weight) * peer.initial_weight
            end
            if not shdict:get(peer.keys.weight) then
                peer:set_weight(new_weight, true)
            end
        end
        
        unique_upstream_peers[peer.name] = peer
        table.insert(upstream_peers_array, peer)
    end
    local upstream = {
        name = upstream_name,
        version = version,
        cp = 1, -- current peer index
        peers = upstream_peers_array, -- peers
        keys = keycache(upstream_name),
        revision = opt.revision or 0
    }
    
    assert(#upstream.peers > 0)
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
        if not s.backup then
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
    return Upstream.new(upstream_name, servers, {nowrap = true})
end

function Upstream.get(upstream_name, opt)
    local check_wrap = true
    if opt and opt.nowrap then check_wrap = false end
    local upstream = upstreams[upstream_name] or (check_wrap and wrap(upstream_name))
    if not upstream then return nil, "unknown upstream ".. upstream_name end
    local shared_revision = shdict:get(upstream.keys.revision)
    if upstream.revision ~= shared_revision then
        --another worker must have changed the upstream. rebuild it.
        local data = shdict:get(upstream.keys.serialized)
        data = cjson.decode(data)
        Upstream.update(upstream_name, data.peers, data)
        upstream = upstreams[upstream_name]
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

function Upstream.new(name, servers, opt)
    if Upstream.get(name, opt) then
        error("upstream \""..name.."\" already exists");
    end
    return Upstream.update(name, servers, opt)
end

return Upstream
