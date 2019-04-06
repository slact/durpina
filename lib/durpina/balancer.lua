-- Copyright (C) by Jianhao Dai (Toruneko)

-- see https://github.com/hamishforbes/lua-resty-iputils.git
local ngx_upstream = require "ngx.upstream"
local Upstream = require "durpina.upstream"
assert(type(Upstream)~="userdata")



local iputils = require "resty.iputils"
iputils.enable_lrucache()
local ngx_balancer = require "ngx.balancer"

local function get_single_peer(ups)
    local _, peer = next(ups.peers)
    if not peer:is_down() then
        return peer
    end
    return nil, "no available peer for upstream " .. tostring(ups.name)
end

local function get_unweighted_round_robin_peer(ups)
    local peercount = #ups.peers

    local cp = ups.cp

    local peer
    repeat
        ups.cp = (ups.cp % peercount) + 1
        peer = ups.peers[ups.cp]

        if not peer then
            return nil, "no peer found in upstream " .. ups.name
        end

        -- visit all peers, but no one avaliable, exit.
        if cp == ups.cp and peer:is_down() then
            return nil, "no available peers in upstream " .. ups.name
        end

    until not peer:is_down()

    return peer
end

local function get_hash_result_peer(ups, hashval)
    local peercount = #ups.peers
    local current = (hashval % peercount) + 1
    local peer = ups.peers[current]

    if not peer then
        return nil, "no peer found in upstream " .. tostring(ups.name)
    end

    if peer:is_down() then
        ups.cp = current
        return get_unweighted_round_robin_peer(ups)
    end

    return peer

end



local function get_source_ip_hash_peer(ups)
    local src, err = math.abs(iputils.ip2bin(ngx.var.remote_addr))
    if not src then
        return nil, err
    end
    return get_hash_result_peer(ups, src)
end

local crc32_short = ngx.crc32_short
local function get_consistent_hash_peer(ups, str)
    assert(type(str)=="string", "expected a string parameter for consistent-hash balancer")
    return get_hash_result_peer(ups, crc32_short(str))
end

local function get_weighted_round_robin_peer(ups)

    local peercount = #ups.peers
    local cp = ups.cp
    local cw = ups.cw
    
    if not cp then
        cp, ups.cp = 1, 1
    end
    if not cw then
        cw = ups.max
        ups.cw = cw
    end
    
    while true do
        if ups.cp == 1 then
            ups.cw = ups.cw - ups.gcd
            if ups.cw <= 0 or not ups.cw then
                ups.cw = ups.max
            end
        end
        ups.cp = (ups.cp % peercount) + 1

        local peer = ups.peers[ups.cp]

        if not peer then
            return nil, "no peer found in upstream " .. ups.name
        end
        local weight = peer:get_weight()
        if weight >= ups.cw and not peer:is_down() then
            return peer
        end
        -- visit all peers, but no one avaliable, exit.
        if ups.cw == cw and ups.cp == cp then
            return nil, "no available peer in upstream " .. ups.name
        end
    end
end

local balancers = {
    ["round-robin"] = get_weighted_round_robin_peer,
    ["unweighted-round-robin"] = get_round_robin_peer,
    ["ip-hash"] = get_source_ip_hash_peer,
    ["consistent-hash"] = get_consistent_hash_peer,
}

local function balance(balancer_name, ...)
    local upstream_name = ngx_upstream.current_upstream_name()
    local up = Upstream.get(upstream_name)
    if not up then
        error("upstream " .. upstream_name " does not exist")
    end
    local balancer = balancers[balancer_name]
    if not balancer then
        local valid = {}
        for n,_ in pairs(balancers) do
            table.insert(valid, "\""..n.."\"")
        end
        error("upstream \""..upstream_name.."\" unknown balancer \""..balancer_name..
              "\"; valid balancers are:" .. table.concat(valid, ", "))
    end
    local ctx = ngx.ctx.durpina_balancer
    if not ctx then
        ctx = {}
        ngx.ctx.durpina_balancer = ctx
    end

    -- check fails
    if ngx_balancer.get_last_failure() then
        local last_peer = ctx.last_peer
        last_peer:add_fail()
    end

    --check retries
    if up.retries and up.retries > 0 and not ctx.retries_set then
        local _, err = ngx_balancer.set_more_tries(up.retries)
        if err then
            ngx.log(ngx.WARN, err)
        end
    end

    local peer, err
    if #up.peers == 1 then
        peer, err = get_single_peer(up)
    else
        peer, err = balancer(up, ...)
    end
    if not peer then
        --what to do?...
        return nil, err
    end
    ctx.last_peer = peer
    ngx_balancer.set_current_peer(peer.address, peer.port)
    return true
end

local Balancer = {
    balance = balance,
    add = function(name, func)
        if balancers[name] then
        error("balancer \"" .. name .. "\" already exists")
        end
    end
}

setmetatable(Balancer, {
    __call = function(tbl, balancer_name, ...)
        return balance(balancer_name, ...)
    end
})

return Balancer
