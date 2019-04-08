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


Synopsis
========

```lua
# nginx.conf:
http {
  lua_shared_dict upstream    1m; #-- shared memory to be used by durpina. 1mb should be neough
  lua_socket_log_errors       off; #-- don't clutter the error log when upstream severs fail
}
  

    
```

Methods
=======

To load this library,

1. you need to specify this library's path in ngx_lua's [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) directive. For example, `lua_package_path "/path/to/lua-resty-upstream/lib/?.lua;;";`.
2. you use `require` to load the library into a local Lua variable:

```lua
    local upstream = require "resty.upstream"
```

init
---
`syntax: upstream.init(config)`

`phase: init_by_lua`

initialize upstream management with configuration:

```nginx
lua_shared_dict upstream  1m;
```

```lua
local config = {
    cache = "upstream",
    cache_size = 1000
}
```

`cache_size` means the max numbers of upstream, and LRU will be work when store upstream more than `cache_size` numbers.

update_upstream
----
`syntax: ok = upstream.update_upstream(u, data)`

update upstream or create new upstream from `data` with name `u`. return true on success.

```lua
local ok = upstream.update_upstream("foo.com", {
    version = 1,
    hosts = {
        {
            name = "127.0.0.1:8080", 
            host = "127.0.0.1", 
            port = 8080,            -- default value
            weight = 100,           -- default value
            max_fails = 3,          -- default value
            fail_timeout = 10,      -- default value, 10 second
            default_down = false    -- default value
        }
    }
})
if not ok then
    return
end
```

The weight, max_fails, fail_timeout options for the sub module [lua-resty-upstream-balancer](https://github.com/toruneko/lua-resty-upstream/blob/master/lib/resty/balancer.md).

And default_down option for sub module [lua-resty-upstream-monitor](https://github.com/toruneko/lua-resty-upstream/blob/master/lib/resty/monitor.md).

delete_upstream
------
`syntax: upstream:delete_upstream(u)`

delete upstream with upstream name `u`

Author
======

Jianhao Dai (toruneko) <toruneko@outlook.com>


Copyright and License
=====================

This module is licensed under the MIT license.

Copyright (C) 2018, by Jianhao Dai (toruneko) <toruneko@outlook.com>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


See Also
========
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
