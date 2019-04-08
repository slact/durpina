# Durpina

Dynamic Upstream Reversy Proxying wIth Nice API

A supremely flexible, easy to use dynamic Nginx/OpenResty upstream module based on lua-resty-upstream by toruneko.

Configurable and scriptable load balancing, server health checks, addition and removal of servers to an upstream, and more. You don't have to study the API to use it, and you don't have to be a Lua wiz to script it.

# Installation

Install OpenResty, then use the `opm` tool to install durpina:
```
opm install slact/durpina
```

# Example Config

```lua
#-- nginx.conf:
http {
  lua_shared_dict upstream    1m; #-- shared memory to be used by durpina. 1mb should be neough
  lua_socket_log_errors       off; #-- don't clutter the error log when upstream severs fail
  
  upstream foo {
    server localhost:8080; #--default weight is 1
    server host1:8080 weight=5;
    server host2:8080 weight=7;
    balancer_by_lua_block {
      --load balance this upstream in round-robin mode
      require "durpina.balancer" "round-robin"
      --note: the above line is Lua syntax sugar equivalent to
      -- require("durpina.balancer")("round-robin")
    }
  }
  
  #-- 
  upstream bar {
    server 0.0.0.0; #-- nginx config syntax needs at least 1 server.
    #-- the address 0.0.0.0 is treated by Durpina as a placeholder and is ignored
    balancer_by_lua_block {
      require "durpina.balancer" "ip-hash"
    }
  }
  
  init_worker_by_lua_block {
    local Upstream = require "durpina.upstream"
    
    --Use the "upstream" lua_shared_dict declared above
    Upstream.init("upstream")

    local upfoo = Upstream.get("foo")
    --add a health check to the upstream
    upfoo:add_monitor("http", {uri="/still_alive"})
    
    local upbar = Upstream.get("bar")
    --this is an upstream with no servers
    
    --peers can be added anytime
    
    upbar:add_peer("localhost:8080 weight=1") --hostnames are resolved once when added, just like Nginx would do
    upbar:add_peer({host="10.0.0.2", port=8090, weight=7, fail_timeout=10}) --can be added as a table, too
    
    upbar:add_monitor("tcp", {port=10000}) -- check if able to make tcp connection to server on port 10000
    upbar:monitor() -- start monitoring right away, instead of waiting until the first request to the upstream
  }
  
  server {
    #-- here's where we make use of the upstream
    listen 80;
    location /foo {
      proxy_pass http://foo;
    }
    location /bar {
      proxy_pass http://bar;
    }
  }
  
  server {
    #-- upstream info and management
    
    listen 8080;
    #-- POST /set_upstream_peer_weight/upstream_name/peer_name
    #-- request body is the peer's new weight
    location ~/set_upstream_peer_weight/foo/(.*)/(\d+) {
      content_by_lua_block {
        local Upstream = require "durpina.upstream"
        local up = Upstream.get("foo")
        
        local peername = ngx.var[1]
        local weight = tonumber(ngx.var[2])
        local peer = up:get_peer(peername)
        if peer and weight then
          peer:set_weight(weight)
          ngx.say("weight set!")
        else
          ngx.status = 404
          ngx.say("peer not found or weight invalid")
        end
      }
    }
  }
}
```

# API

## Upstream
```lua
Upstream = require "durpina.upstream"
```

### `Upstream.init(shdict_name)`

Initialize Durpina to use the [`lua_shared_dict`](https://github.com/openresty/lua-nginx-module/#lua_shared_dict) named `shdict_name`. **This call is required** before anything else, and must be present in the [`init_worker_by_lua`](https://github.com/openresty/lua-nginx-module/#init_worker_by_lua) string, block or file.

A block of size 1m is sufficient for most setups.

### Upstream.get(upstream_name)
```lua
  local upstream = Upstream.get("foo")
```
Returns the upstream named `upstream_name`, with peers initialized according to the contents of the corresponding [`upstream`](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#upstream) block. Upstream peers marked as `backup` or with address `0.0.0.0` are ignored.

### upstream:add_peer(peer_config)
```lua
upstream:add_peer("localhost:8080 fail_timeout=15 weight=7")
upstream:add_peer({name="localhost:8080", fail_timeout=15, weight=7})
upstream:add_peer({host="localhost", port=8080, fail_timeout=15, weight=7})
```

Add peer to the upstream. The `peer_config` parameter may be a string with the formatting of the [`server`](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#server) upstream directive, or a Lua table with the following keys: `name` ("host:port"), `host`, `port`, `fail_timeout`, `weight`. Either `name` or `host` must be present in the table.

Server hostnames resolution is deferred until the server has been selected during load balancing.

# **THIS DOCUMENTATION IS INCOMPLETE**.
more to follow.
