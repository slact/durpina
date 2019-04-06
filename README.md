Durpina
=============

Dynamic Upstream Reversy Proxying wIth Nice API

A supremely flexible, easy to use dynamic Nginx upstream module based on lua-resty-upstream by toruneko.

Status
======

This library is considered production ready.

Build status: [![Travis](https://travis-ci.org/toruneko/lua-resty-upstream.svg?branch=master)](https://travis-ci.org/toruneko/lua-resty-upstream)

Description
===========

This library requires an nginx build with [ngx_lua module](https://github.com/openresty/lua-nginx-module), and [LuaJIT 2.0](http://luajit.org/luajit.html).

Dependencies
==========

- [lua-resty-core](https://github.com/openresty/lua-resty-core)
- [ngx.balancer](https://github.com/openresty/lua-resty-core/blob/master/lib/ngx/balancer.md)
- [lua-resty-lrucache](https://github.com/openresty/lua-resty-lrucache)
- [lua-resty-iputils](https://github.com/hamishforbes/lua-resty-iputils)
- [lua-resty-http](https://github.com/pintsized/lua-resty-http)

Synopsis
========

```lua
    # nginx.conf:

    lua_package_path "/path/to/lua-resty-upstream/lib/?.lua;;";
    lua_shared_dict upstream    1m;
    lua_shared_dict monitor 1m;
    
    server {
        location = /t {
            content_by_lua_block {
                local upstream = require "resty.upstream"
                upstream.init({
                    cache = "upstream",
                    cache_size = 100
                })
                -- update foo.com upstream
                local ok = upstream.update_upstream("foo.com", {
                    version = 1,
                    hosts = {
                        {
                            name = "127.0.0.1:8080", 
                            host = "127.0.0.1", 
                            port = 8080, 
                            weight = 100, 
                            max_fails = 3, 
                            fail_timeout = 10, 
                            default_down = false
                        }
                    }
                })
                if not ok then
                    return
                end

                local monitor = require "resty.upstream.monitor"
                local ok, err = monitor.spawn_checker({
                    shm = "monitor",
                    upstream = "foo.com",
                    type = "http",
                    http_req = "HEAD /status HTTP/1.0\r\nHost: foo.com\r\n\r\n",
                    -- if required "lua-resty-http"
                    -- http_req = {
                    --     method = "HEAD",
                    --     path = "/ok.htm"
                    --     headers = {
                    --         Host = "foo.com"
                    --     }
                    -- }
                    interval = 2000,
                    timeout = 1000,
                    fall = 3,
                    rise = 2,
                    valid_statuses = {200, 302},
                    concurrency = 10,
                })
                if not ok then
                    upstream.delete_upstream("foo.com")
                    ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
                    return
                end
            }
        }
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
