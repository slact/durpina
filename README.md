Durpina
=============

Dynamic Upstream Reversy Proxying wIth Nice API

A supremely flexible, easy to use dynamic Nginx/OpenResty upstream module based on lua-resty-upstream by toruneko.

Configurable and scriptable load balancing, server health checks, addition and removal of servers to an upstream, and more. You don't have to study the API to use it, and you don't have to be a Lua wiz to script it.

Installation
==========

Install OpenResty, then use the `opm` tool to install durpina:
```
opm install slact/durpina
```

Example Config
========

```lua
# nginx.conf:
http {
  lua_shared_dict upstream    1m; #-- shared memory to be used by durpina. 1mb should be neough
  lua_socket_log_errors       off; #-- don't clutter the error log when upstream severs fail
  
  upstream myapp {
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
  
  init_worker_by_lua_block {
    local Upstream = require "durpina.upstream"
    
    --Use the "upstream" lua_shared_dict declared above
    Upstream.init("upstream")

    local up = Upstream.get("weighted_roundrobin")
    
    --add a health check to the upstream
    up:add_monitor("http", {uri="/still_alive"})
  }
  
  server {
    #-- here's where we make use of the upstream
    listen 80;
    location / {
      proxy_pass http://myapp;
    }
  }
  
  server {
    #-- upstream info and management
    
    listen 8080;
    #-- POST /set_upstream_peer_weight/upstream_name/peer_name
    #-- request body is the peer's new weight
    location ~/set_upstream_peer_weight/(.*) {
      content_by_lua_block {
        local Upstream = require "durpina.upstream"
        local up = Upstream.get("myapp")
        
        ngx.req.read_body()
        local peername = ngx.var[1]
        local weight = tonumber(ngx.req.get_body_data())
        if not weight then
          ngx.status = 400
          return ngx.say("bad weight")
        end
        local peer = up:get_peer(peername)
        if not peer then
          ngx.status = 404
          return ngx.say("peer not found")
        end
        
        --set the weight!
        peer:set_weight(weight)
        return ngx.say("weight set!")
      }
    }
  }
}
```

Usage
=======




See Also
========
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
