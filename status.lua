-- 检测后端的状态
local etcd = require('lrue.etcd')
local conf = require('lrue.config')

local say = ngx.say

local etcdc, err = etcd.New(conf.etcd_host, conf.etcd_port)
if err then
    say('etcd new failed: ' .. err)
    return
end

local body
body, err = etcdc:Version()
if err then
    say('check health is failed,' .. err)
    return
elseif body then
    say('check health is OK, etcd etcdserver: ' .. body.etcdserver)
end
