-- Copyright (C) by Jianhao Dai (Toruneko)
require "resty.upstream.math"

local LOGGER = ngx.log
local NOTICE = ngx.NOTICE

local shared = ngx.shared

local shdict --dictionary shared between processes
local upstreams = {}
local cjson = require "cjson"

local Upstream = {
    _VERSION = '0.1.0'
}
local peer_meta = {__index= {
    get_weight = function(self)
        return shdict:get(self.keys.weight)
    end,
    set_weight = function(self, weight, skip_upstream_recalculate)
        local upstream = self:get_upstream()
        shdict:set(self.keys.weight, weight)
        if not skip_upstream_recalculate then
            upstream:calculate_weights()
        end
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
}}

local upstream_meta = {__index={
    calculate_weights = function(self)
        local gcd, max = 0, 0
        for _, peer in pairs(self.peers) do
            gcd = math.gcd(peer.weight, gcd)
            max = math.max(max, peer.weight)
        end
        self.gcd = gcd
        self.max = max
        return true
    end,
    get_peer = function(self, peer_name)
        for _, peer in pairs(self.peers) do
            if peer.name == peer_name then
                return peer
            end
        end
    end
}}

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

function Upstream.init(config)
    local shared_dict = shared[config.cache]
    if not shared then
        error("no shared dictionary")
    end
    Upstream.default_port = config.default_port or 8080
    shdict = shared_dict
end

function Upstream.update(upstream_name, data)
    local version = tonumber(data.version)
    local hosts = data.hosts
    if not hosts then
        LOGGER(NOTICE, "no hosts data for upstream " .. upstream_name)
        return false
    end

    local oldup = upstreams[upstream_name]
    local unique_upstream_peers = { }
    local upstream_peers_array = {}
    for i, peer in ipairs(hosts) do
        peer.port = tonumber(peer.port) or Upstream.default_port
        if peer.host then
            peer.name = ("%s:%i"):format(peer.name, peer.host)
        end
        if not peer.name or not peer.host then
            LOGGER(NOTICE,"missing upstream server name or host for server " .. i .. " in upstream " .. upstream_name)
            return false
        end

        if unique_upstream_peers[peer.name] then
            LOGGER(NOTICE,"upstream server named \""..peer.name.."\" already exists in upstream " .. upstream_name)
            return false
        end
        local newpeer = {
            name = peer.name,
            host = peer.host,
            default_down = peer.default_down,
            port = tonumber(peer.port) or 8080,
            initial_weight = tonumber(peer.weight or peer.initial_weight) or 100,
            max_fails = tonumber(peer.max_fails) or 3,
            fail_timeout = tonumber(peer.fail_timeout) or 10,
            keys = keycache(upstream_name, peer.name),
            upstream_name = upstream_name
        }
        setmetatable(peer, peer_meta)
        local oldpeer = oldup and oldup:get_peer(peer.name)
        if peer.default_down and not oldpeer then
            peer:set_down()
        end
        if not oldpeer then
            peer:set_weight(peer.initial_weight, true)
        elseif oldpeer.initial_weight ~= peer.initial_weight then
            --use the current weight as a scaling factor for new weight
            local oldweight = oldpeer:get_weight()
            peer:set_weight(math.ceil(oldweight/oldweight.initial_weight) * peer.initial_weight, true)
        end
        unique_upstream_peers[peer.name] = newpeer
        table.insert(upstream_peers_array, newpeer)
    end

    local upstream = {
        name = upstream_name,
        version = version,
        cp = 1, -- current peer index
        peers = upstream_peers_array, -- peers
        keys = keycache(upstream_name)
    }
    setmetatable(upstream, upstream_meta)
    upstream:calculate_weights()
    if not data.no_revision_update then
        upstream.revision = shdict:incr(upstream.keys.revision, 1, 0)
    end
    assert(upstream.revision == shdict:get(upstream.keys.revision))
    shdict:set(upstream.keys.serialized, cjson.encode(upstream))
    upstreams[upstream_name] = upstream
    return upstream
end

function Upstream.delete_upstream(u)
    --TODO
end

function Upstream.get(upstream_name)
    local upstream = upstreams[upstream_name]
    if not upstream then return nil, "unknown upstream ".. upstream_name end
    if upstream.revision ~= shdict:get(upstream.keys.revision) then
        --another worker must have changed the upstream. rebuild it.
        local data = cjson.decode(shdict:get(upstream.keys.serialized))
        Upstream.update(upstream_name, data)
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

return Upstream
