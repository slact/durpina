-- Copyright (C) by Jianhao Dai (Toruneko)

-- see https://github.com/hamishforbes/lua-resty-iputils.git
local iputils = require "resty.iputils"
iputils.enable_lrucache()

local ngx_balancer = require "ngx.balancer"
local Upstream = require "resty.upstream"


local function get_single_peer(ups)
    local _, peer = next(ups.peers)
    if not oeer:is_down() then
        return peer
    end
    return nil, "no available peer for upstream " .. tostring(ups.name)
end

local function get_round_robin_peer(upstream_name)
    local ups, err = Upstream.get(upstream_name)
    if not ups then
        return nil, err
    end

    local peercount = #ups.peers

    if peercount then
        return get_single_peer(ups)
    end

    local cp = ups.cp

    local peer
    repeat
        ups.cp = (ups.cp % peercount) + 1
        peer = ups.peers[ups.cp]

        if not peer then
            return nil, "no peer found in upstream " .. upstream_name
        end

        -- visit all peers, but no one avaliable, exit.
        if cp == ups.cp and peer:is_down() then
            return nil, "no available peers in upstream " .. upstream_name
        end

    until not peer:is_down()

    return peer
end

local function get_source_ip_hash_peer(upstream_name)
    local ups, err = Upstream.get(upstream_name)
    if not ups then
        return nil, err
    end
    local peercount = #ups.peers
    if peercount == 1 then
        return get_single_peer(ups)
    end

    local src, err = math.abs(iputils.ip2bin(ngx.var.remote_addr))
    if not src then
        return nil, err
    end
    local current = (src % peercount) + 1
    local peer = ups.peers[current]

    if not peer then
        return nil, "no peer found in upstream " .. tostring(upstream_name)
    end

    if peer:is_down() then
        return get_round_robin_peer(upstream_name)
    end

    return peer
end

local function get_weighted_round_robin_peer(upstream_name)
    local ups, err = Upstream.get(upstream_name)
    if not ups then
        return nil, err
    end

    local peercount = #ups.peers

    if #peercount == 1 then
        return get_single_peer(ups)
    end

    local cp = ups.cp
    local cw = ups.cw

    while true do
        ups.cp = (ups.cp % peercount) + 1
        if ups.cp == 1 then
            ups.cw = ups.cw - ups.gcd
            if ups.cw <= 0 then
                ups.cw = ups.max
            end
        end

        local peer = ups.peers[ups.cp]

        if not peer then
            return nil, "no peer found in upstream " .. upstream_name
        end
        local weight = peer:get_weight()
        if weight >= ups.cw and not peer:is_down() then
            return peer
        end
        -- visit all peers, but no one avaliable, exit.
        if ups.cw == cw and ups.cp == cp then
            return nil, "no available peer in upstream " .. upstream_name
        end
    end
end

local function proxy_pass(peer_factory, upstream_name, tries, include)
    if not type(peer_factory) == "function" then
        error("peer_factory must be a function")
    end
    tries = tonumber(tries) or 0
    if not include then
        tries = tries - 1
    end

    if tries <= 0 then
        local peer, err = peer_factory(upstream_name)
        if not peer then
            return nil, err
        end
        return ngx_balancer.set_current_peer(peer.host, peer.port)
    end

    local ctx = ngx.ctx

    -- check fails
    if ngx_balancer.get_last_failure() then
        local last_peer = ctx.balancer_last_peer
        last_peer:add_fail()
    end

    -- check tries
    if not ctx.balancer_proxy_times then
        ctx.balancer_proxy_times = 0
    end
    if include and ctx.balancer_proxy_times >= tries then
        return nil, "max tries"
    end

    local peer, err = peer_factory(upstream_name)
    if not peer then
        return nil, err
    end

    -- check and set more tries
    if ctx.balancer_proxy_times < tries then
        local ok, err = ngx_balancer.set_more_tries(1)
        if not ok then
            return nil, err
        end
    end

    ctx.balancer_last_peer = peer
    ctx.balancer_proxy_times = ctx.balancer_proxy_times + 1
    return ngx_balancer.set_current_peer(peer.host, peer.port)
end

local mt = { __index = ngx_balancer }
local _M = setmetatable({
    _VERSION = Upstream._VERSION,
    get_round_robin_peer = get_round_robin_peer,
    get_source_ip_hash_peer = get_source_ip_hash_peer,
    get_weighted_round_robin_peer = get_weighted_round_robin_peer,
    proxy_pass = proxy_pass
}, mt)

return _M
