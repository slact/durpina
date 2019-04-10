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
    --setting the resolver is required for upstream server DNS resolution
    Upstream.init("upstream", {resolver="8.8.8.8"})

    local upfoo = Upstream.get("foo")
    --add a health check to the upstream
    upfoo:add_monitor("http", {uri="/still_alive"})
    
    local upbar = Upstream.get("bar")
    --this is an upstream with no servers
    
    --peers can be added anytime
    
    upbar:add_peer("localhost:8080 weight=1") --hostnames are resolved once when added, just like Nginx would do
    upbar:add_peer({host="10.0.0.2", port=8090, weight=7, fail_timeout=10}) --can be added as a table, too
    
    upbar:add_monitor("tcp", {port=10000}) -- check if able to make tcp connection to server on port 10000
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
<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Upstream](#upstream)
  - [`Upstream.init(shdict_name, options)`](#upstreaminitshdict_name-options)
  - [`Upstream.get(upstream_name)`](#upstreamgetupstream_name)
  - [`upstream.name`](#upstreamname)
  - [`upstream:get_peer(peer_name)`](#upstreamget_peerpeer_name)
  - [`upstream:add_peer(peer_config)`](#upstreamadd_peerpeer_config)
  - [`upstream:remove_peer(peer)`](#upstreamremove_peerpeer)
  - [`upstream:get_peers(selector)`](#upstreamget_peersselector)
  - [`upstream:add_monitor(name, opts)`](#upstreamadd_monitorname-opts)
  - [`upstream:info()`](#upstreaminfo)
- [Peer](#peer)
  - [`peer.name`](#peername)
  - [`peer.port`](#peerport)
  - [`peer.initial_weight`](#peerinitial_weight)
  - [`peer:get_address()`](#peerget_address)
  - [`peer:get_weight()`](#peerget_weight)
  - [`peer:set_weight(weight)`](#peerset_weightweight)
  - [`peer:get_upstream()`](#peerget_upstream)
  - [`peer:set_state(state)`](#peerset_statestate)
  - [`peer:is_down(kind)`](#peeris_downkind)
  - [`peer:is_failing()`](#peeris_failing)
  - [`peer:add_fail()`](#peeradd_fail)
  - [`peer:resolve(force)`](#peerresolveforce)
- [Balancer](#balancer)
  - [`Balancer(algorithm, args...)`](#balanceralgorithm-args)
  - [`Balancer.balance(algorithm, args...)`](#balancerbalancealgorithm-args)
- [Monitor](#monitor)
  - [Predefined Monitors](#predefined-monitors)
    - [`http`](#http)
    - [`tcp`](#tcp)
    - [`haproxy-agent-check`](#haproxy-agent-check)
    - [`http-haproxy-agent-check`](#http-haproxy-agent-check)
  - [Registering New Monitors](#registering-new-monitors)
    - [`Monitor.register(name, check)`](#monitorregistername-check)
      - [`monitor check_table.init`](#monitor-check_tableinit)
      - [`monitor check_table.check`](#monitor-check_tablecheck)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Upstream
```lua
  Upstream = require "durpina.upstream"
```

### `Upstream.init(shdict_name, options)`
```lua
  init_worker_by_lua_block {
    Upstream.init("myshdict", {resolver="8.8.8.8"})
  }
```
Initialize Durpina to use the [`lua_shared_dict`](https://github.com/openresty/lua-nginx-module/#lua_shared_dict) named `shdict_name`. **This call is required** before anything else, and must be present in the [`init_worker_by_lua`](https://github.com/openresty/lua-nginx-module/#init_worker_by_lua) string, block or file. A block of size 1m is sufficient for most setups.

The `options` argument supports the following parameters:
 - `resolver`: a string or array or strings to be used as nameservers for DNS resolution. This is **required** if server hostnames need to be resolved after Nginx startup.
 
### `Upstream.get(upstream_name)`
```lua
  local upstream = Upstream.get("foo")
```
Returns the upstream named `upstream_name`, with peers initialized according to the contents of the corresponding [upstream](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#upstream) block. Upstream peers marked as `backup` or with address `0.0.0.0` are ignored.

### `upstream.name`
The name of this upstream.

### `upstream:get_peer(peer_name)`
```lua
  local peer = upstream:get_peer("localhost:8080")
```
Returns the [peer](#Peer) with name `peer_name` or nil if no such [peer](#Peer) exists in this upstream.

### `upstream:add_peer(peer_config)`
```lua
  local peer, err = upstream:add_peer("localhost:8080 fail_timeout=15 weight=7")
  local peer, err = upstream:add_peer({name="localhost:8080", fail_timeout=15, weight=7})
  local peer, err = upstream:add_peer({host="localhost", port=8080, fail_timeout=15, weight=7})
```

Add peer to the upstream. The `peer_config` parameter may be a string with the formatting of the [`server`](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#server) upstream directive, or a Lua table with the following keys: `name` ("host:port"), `host`, `port`, `fail_timeout`, `weight`. Either `name` or `host` must be present in the table.

No two peers in an upstream block may have the same name.

Returns the newly added [peer](#Peer) or `nil, error`

### `upstream:remove_peer(peer)`
```lua
  local peer = upstream:get_peer("localhost:8080")
  loal ok, err = upstream:remove_peer(peer)
```
Removes the [peer](#Peer) from the upstream.

### `upstream:get_peers(selector)`
```lua
  local peers = upstream:get_peers("all")
```
Returns an array of [peers](#Peer) matching the `selector`, which can be one of: `nil` (same as `all`), `"all"`, `"failing"`, `"down"`, `"temporary_down"`, `"permanent_down"`.

### `upstream:add_monitor(name, opts)`
```lua
  local ok, err = upstream:add_monitor("http", {url="/health_check"})
```
Adds a [`monitor`](#Monitor) to the upstream. Monitors periodically check each peer for health, and are discussed in more detail in the [Monitors](#Monitor) section.


### `upstream:info()`
```lua
  print(upstream:info())
```
```json
  /* output */
  {
    "name":"weighted_roundrobin",
    "revision":2,
    "peers":[{
        "name":"localhost:8083",
        "address":"127.0.0.1",
        "weight":1,
        "state":"up"
      },{
        "name":"127.0.0.1:8084",
        "address":"127.0.0.1",
        "weight":10,
        "state":"failing"
      },{
        "name":"127.0.0.1:8085",
        "address":"127.0.0.1",
        "weight":15,
        "state":"down"
      }],
    "monitors":[{
        "id":"http",
        "name":"http"
      }]
  }

```

Returns a JSON string containing state info about this upstream.

## Peer

Peers are servers in an [upstream](#Upstream). They are initialized internally -- although there's a Peer.new method, you really shouldn't use it. Instead, peers are created with [`upstream:add_peer()`](#upstreamadd_peerpeer_config) and by being loaded from [upstream blocks](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#upstream).

```lua
  local peer = upstream:get_peer("127.0.0.1")
```

### `peer.name`
The name of the peer, of the form `"hostname:port"`

### `peer.port`

The port, obviously.

### `peer.initial_weight`

The weight the peer was originally loaded with, unmodified by later calls to [`peer:set_weight(n)`](#peerset_weightweight)

### `peer:get_address()`
```lua
  local address, err = peer:get_address()
```
Returns the peer address if it has already been resolved. If the address is unavailable or the DNS resolution has failed, returns `nil, err`.

### `peer:get_weight()`
```
  local weight = peer:get_weight()
```

Returns the peer's current weight.

### `peer:set_weight(weight)`
```
  local ok, err = peer:set_weight(15)
```

Sets the peer's current weight for all Nginx workers. The weight must be a positive integer.

### `peer:get_upstream()`
```
  local upstream = peer:get_upstream()
```

Returns the [`upstream`](#Upstream) of this peer.

### `peer:set_state(state)`
```
  peer:set_state("down")
```

Sets the state of the peer, shared between all Nginx workers. Can be one of `up`, `down`, or `temporary_down`

### `peer:is_down(kind)`

Returns `true` if the peer is down. The parameter `kind` can be `nil` or one of `"any"`, `"permanent"` or `"temporary"`, and reflects the kind down state the peer is in. The default value of `kind` is `"any"`.

### `peer:is_failing()`

Returns `true` if the peer is currently failing; that is, if it has recorded more than one failure in the last `fail_timeout` time interval.

### `peer:add_fail()`

Increment the failure counter of the peer by 1. This counter is shared among all Nginx workers.

### `peer:resolve(force)`

Resolve the peer hostname to its address if necessary. if `force` is true, overwrites the existing address if it's present. Like other `peer` updates, the newly resolved address is automatically shared between Nginx workers.

In order for peer DNS resolution to work, [Upstream.init()](#upstreaminitshdict_name-options) must be given a `resolver`.

## Balancer
```lua
  require "durpina.balancer"
```

The balancer is invoked in [upstream blocks](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#upstream) using the [`balancer_by_lua`](https://github.com/openresty/lua-nginx-module#balancer_by_lua_block) block:

```lua
  upstream foo {
    localhost:8080 weight=2;
    localhost:8081;
    balancer_by_lua_block {
      require "durpina.balancer" "round-robin"
      --this is syntactic sugar equivalent to
      -- require("durpina.balancer").balance("round-robin")
    }
  }
```
### `Balancer(algorithm, args...)`
### `Balancer.balance(algorithm, args...)`
```lua
  Balancer.balance(algorithm)
```

Balance the upstream using the specified `algorithm`, The following algorithms are supported:

  - **"`round-robin`"** (weighted)
  - **"`unweighted-round-robin`"**
  - **"`ip-hash`"**, consistent routing based on source IP
  - **"`consistent-hash`"**, consistent routing based on custom request variables

The `args...` parameters are passed directly to the balancer. Currently only the `consistent-hash` algorithm expects a parameter, the value to be hashed:
```lua
balancer_by_lua_block {
  --load-balance by the first regex capture in the request url
  require "durpina.balancer" ("consistent-hash", ngx.var[1])
}
```

## Monitor
```lua
  upstream:add_monitor(name, opts)
```
Monitors are added to upstreams to check the health status of peers, and to run periodic maintenance tasks. Monitors are not initialized directly, but are added via the [`upstream:add_monitor()`](#upstreamadd_monitorname-opts) call. 

The monitor `name` identifies the kind of monitor being added. [Several monitors](#predefined-monitors) are already included, and more can be added with [`Monitor.register()`](#monitorregistername-check).

Each new monitors is passed the `opts` table of options. This table **may only contain numeric or string values**. All monitors handle the `opts` key `id`, which uniquely identifies a monitor in an upstream. When absent, the `id` defaults to the monitor `name`. Therefore to have more than one `http` monitor, at least one must be given an id:
```lua
  upstream:add_monitor("http") --pings the root url
  upstream:add_monitor("http", {id="http_hello", url="/hello", interval=30})
```

In total, the following `opts` are used by all monitors:
  - **`id`**:  uniquely identifies the monitor.  
    Default: monitor name
  - **`interval`**: time between each check. One peer is checked at the end of
    every interval, split between all Nginx workers. Can be a 
    number or an Nginxy time string ("10s", "30m", etc.)  
    Default: `Monitor.default_interval` (5 seconds)
  - **`port`**: Perform the monitor check by connecting to this port instead 
    of the peer's upstream port.
  - **`peers`**: The kind of peers to check over. Can be one of the selectors from
    [`upstream:get_peers()`](#upstreamget_peersselector).  
    Default: `"all"`

### Predefined Monitors

#### `http`

Send an HTTP request, add failure if the request fails.

```lua
  upstream:add_monitor("http", {id="http-hello", url="/hello", ok_codes="2xx", interval="5m"})
```

`opts`:
  - **`url`**: /path/to/request  
    Default: `"/"`
  - **`ok_codes`**: response codes considered "ok". space-delimited string with code numbers and 'Nxx' notation.  
    Default: `"101 102 2xx 3xx"`
  - **`header_*`**: all opts prefixed by "header_" become request headers
  - **`method`**: request method.  
    Default: `"GET"`
  - **`body`**: request body.  
    Default: `nil`

#### `tcp`

Try to connect to server via a TCP socket, add failure if the connection fails.

```lua
  upstream:add_monitor("tcp", {id="tcp-ping", timeout=200})
```

`opts`:
  - **`timeout`**: connection timeout, in milliseconds  
    Default: [OpenResty defaults](https://github.com/openresty/lua-nginx-module#lua_socket_connect_timeout)


#### `haproxy-agent-check`

Try to connect to peer over TCP and read one line of text. The data is processed according to the 
[HAProxy agent-check](https://cbonte.github.io/haproxy-dconv/1.9/configuration.html#5.2-agent-check) specification.
The statuses "drain" and "maint" are treated as "down", and "up" and "ready" are both treated as "up".

```lua
  upstream:add_monitor("haproxy-agent-check", {timeout=200})
```

**`opts`**:
  - **`timeout`**: connection timeout, in milliseconds  
    Default: [OpenResty defaults](https://github.com/openresty/lua-nginx-module#lua_socket_connect_timeout)

#### `http-haproxy-agent-check`

Same as [haproxy-agent-check](#haproxy_agent_check), but over HTTP.

```lua
  upstream:add_monitor("haproxy-agent-check", {url="/haproxy_agent_status"})
```

`opts`:
  - **`url`**: /path/to/request  
    Default: `"/"`
  - **`ok_codes`**: response codes considered "ok". space-delimited string with code numbers and 'Nxx' notation.  
    Default: "101 102 2xx 3xx"
  - **`header_*`**: all opts prefixed by "header_" become request headers

### Registering New Monitors

New monitors are added with `Monitor.register`

#### `Monitor.register(name, check)`
```lua
  Monitor.register("fancy_monitor", check_function)
  -- or --
  Monitor.register("fancy_monitor", check_table)
```

Register a monitor by name to be added to upstreams later. `Check` can be a table or function:

```lua
  init_worker_by_lua_block {
    -- register as a table
    Monitor.register("mymonitor", {
      init = initialization_function, -- (optional)
      check = peer_checking_function, --(required)
      interval = default interval for this monitor --(optional)
    }
    
    --register as a function
    Monitor.register("mymonitor", peer_checking_function)
      -- is equivalent to --
    Monitor.register("mymonitor", {
      check = peer_checking_function
    })
  }
```
##### `monitor check_table.init`
The `init` function is called every time the monitor is added to an upstream. It is responsible for initializing monitor state and validating `opts`. It has the signature
```lua
  function init_monitor(upstream, shared, local_state)
```
The parameters are:
 - **`upstream`** the [upstream](#upstream) this monitor is being added to.
 - **`shared`** is an openresty [shared dictionary](https://github.com/openresty/lua-nginx-module#ngxshareddict) namespaced to this instance of the monitor.
 - **`local_state`** is a worker-local table for tracking execution state, caching, and configuration. It is initialized as a copy of the `opts` table passed to [upstream:add_monitor()](#upstreamadd_monitorname-opts)
 
##### `monitor check_table.check`
The `check` function is called on each successive peer at the configured interval. It is responsible for changing peer state with [`peer:set_state()`](#peerset_statestate) and other [`peer`](#Peer) functions. It has the signature
```lua
  function check_monitor(upstream, peer, shdict, local_state)
```
The parameters are:
 - **`upstream`** the [upstream](#upstream) this monitor is being added to.
 - **`peer`** the [peer](#Peer) that needs to be checked.
 - **`shared`** is an openresty [shared dictionary](https://github.com/openresty/lua-nginx-module#ngxshareddict) namespaced to this instance of the monitor.
 - **`local_state`** is a worker-local table for tracking execution state, caching, and configuration. It is initialized as a copy of the `opts` table passed to [upstream:add_monitor()](#upstreamadd_monitorname-opts)
 
More details on how to create monitors will be added later.
 
 
