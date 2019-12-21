local b = require("ngx.balancer")
local dyups = require("lrue.dyups")

local server = dyups.find(ngx.var.upstream, ngx.var.remote_addr, ngx.var.hash_method)
if server then
    assert(b.set_current_peer(server))
end
