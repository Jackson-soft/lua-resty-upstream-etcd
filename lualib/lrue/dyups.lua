-- 动态 upstream
local cjson = require('cjson.safe')
local typeof = require('typeof')

local _M = {}

local ngx_timer_at = ngx.timer.at
local ngx_sleep = ngx.sleep
local ngx_worker_exiting = ngx.worker.exiting
local decodeJson = cjson.decode
local encodeJson = cjson.encode
local tonumber = tonumber

local log = ngx.log
local ERR = ngx.ERR
local INFO = ngx.INFO

_M.ready = false
_M.data = {}

local function length(T)
    local count = 0
    for _ in pairs(T) do
        count = count + 1
    end
    return count
end

local function isTableEmpty(t)
    if not t or t == nil or _G.next(t) == nil then
        return true
    else
        return false
    end
end

local function copyTab(orig)
    local copy
    if typeof.table(orig) then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[copyTab(orig_key)] = copyTab(orig_value)
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

local function indexOf(t, e)
    for k, v in pairs(t) do
        if v.host == e.host and v.port == e.port then
            return k
        end
    end
    return nil
end

-- 比如传入 xxx/key 则返回 key xxx
local function baseName(s)
    local x, y = s:match('(.*)/([^/]*)/?')
    return y, x
end

-- 分离upstream 的name跟host:port
local function separateKey(s)
    if not _M.conf then
        return nil, nil
    end
    return s:match(_M.conf.etcd_key .. '/(.*)/([^/]*)/?')
end

-- 分离IP跟 port
local function split_addr(s)
    local host, port = s:match('(.*):([0-9]+)')

    -- verify the port
    local p = tonumber(port)
    if p == nil then
        return '127.0.0.1', 0, 'port invalid'
    elseif p < 1 or p > 65535 then
        return '127.0.0.1', 0, 'port invalid'
    end

    -- verify the ip address
    local chunks = {host:match('(%d+)%.(%d+)%.(%d+)%.(%d+)')}
    if (#chunks == 4) then
        for _, v in pairs(chunks) do
            if (tonumber(v) < 0 or tonumber(v) > 255) then
                return '127.0.0.1', 0, 'host invalid'
            end
        end
    else
        return '127.0.0.1', 0, 'host invalid'
    end

    -- verify pass
    return host, port, nil
end

local function get_lock()
    local dict = _M.conf.dict
    local key = 'lock'
    -- only the worker who get the lock can update the dump file.
    local ok, err = dict:add(key, true)
    if not ok then
        if err == 'exists' then
            return false
        end
        log(ERR, 'failed to add key "', key, '": ', err)
        return false
    end
    return true
end

local function release_lock()
    local dict = _M.conf.dict
    local key = 'lock'
    local ok, err = dict:delete(key)
    if err then
        log(ERR, err)
    end
    return ok
end

-- dump 到本地
local function dumpToFile(force)
    local cur_v = _M.data.version
    log(INFO, 'dump to file: ' .. cur_v)
    local saved = false
    local dict = _M.conf.dict
    while not saved do
        local pre_v = dict:get('version')
        if not force then
            if pre_v then
                if tonumber(pre_v) >= tonumber(cur_v) then
                    return true
                end
            end
        end

        local l = get_lock()
        if l then
            local f_path = _M.conf.dump_file .. '_' .. _M.conf.etcd_key
            local file, err = io.open(f_path, 'w+')
            if not file then
                log(ERR, "Can't open file: " .. f_path .. err)
                release_lock()
                return false
            end

            local data = encodeJson(_M.data)
            file:write(data)
            file:flush()
            file:close()

            dict:set('version', cur_v)
            saved = true
            release_lock()
        else
            ngx_sleep(0.2)
        end
    end
end

local function set_healthcheck(upstream, value)
    local check
    if not _M.data[upstream] then
        _M.data[upstream] = {}
    end
    if _M.data[upstream].healthcheck then
        check = _M.data[upstream].healthcheck
    end
    local check_type, check_req, check_interval, check_timeout, check_rise, check_concurrency, check_fall, check_valid
    if not check then
        check_type = _M.conf.check_type or 'http'
        check_req = _M.conf.check_req or 'GET /1.htm HTTP/1.0\r\nHost: foo.com\r\n\r\n'
        check_interval = _M.conf.check_interval or 3000
        check_timeout = _M.conf.check_timeout or 2000
        check_rise = _M.conf.check_rise or 2
        check_concurrency = _M.conf.check_concurrency or 10
        check_fall = _M.conf.check_fall or 3
        check_valid = _M.conf.check_valid or {200}
    else
        if check['typ'] then
            check_type = check['typ']
        end
        if check['http_req'] then
            check_req = check['http_req']
        end
        if check['interval'] then
            check_interval = check['interval']
        end
        if check['timeout'] then
            check_timeout = check['timeout']
        end
        if check['rise'] then
            check_rise = check['rise']
        end
        if check['concurrency'] then
            check_concurrency = check['concurrency']
        end
        if check['fall'] then
            check_fall = check['fall']
        end
        if check['valid_statuses'] then
            check_valid = check['valid_statuses']
        end
    end
    if value.type then
        check_type = value.type
    end
    if value.http_req then
        check_req = value.http_req
    end
    if value.interval then
        check_interval = value.interval
    end
    if value.timeout then
        check_timeout = value.timeout
    end
    if value.rise then
        check_rise = value.rise
    end
    if value.fall then
        check_fall = value.fall
    end
    if value.concurrency then
        check_concurrency = value.concurrency
    end
    if value.valid_statuses then
        check_valid = value.valid_statuses
    end

    _M.data[upstream].healthcheck = {
        typ = check_type,
        http_req = check_req,
        interval = check_interval,
        timeout = check_timeout,
        rise = check_rise,
        concurrency = check_concurrency,
        valid_statuses = check_valid,
        fall = check_fall
    }
end

local function spawn_healthcheck(upstream)
    local hc = require('lrue.healthcheck')

    if not _M.data[upstream].healthcheck then
        set_healthcheck(upstream, {})
        log(INFO, 'upstream:' .. upstream .. ' use default healthcheck')
    end
    local check = _M.data[upstream].healthcheck
    return hc.spawn_checker(
        {
            dict = _M.conf.dict,
            upstream = upstream,
            type = check.typ,
            http_req = check.http_req,
            interval = check.interval,
            timeout = check.timeout,
            rise = check.rise,
            fall = check.fall,
            valid_statuses = check.valid_statuses,
            concurrency = check.concurrency
        }
    )
end

-- 初始化upstream的轮训算法
local function hash_server(name)
    local resty_chash = require('resty.chash')
    local resty_rr = require('resty.roundrobin')
    local server_list = _M.data[name].up_servers
    local count = length(server_list)
    if count == 0 then
        _M[name] = nil
        log(ERR, 'upstream:', name, ' not have a node')
        return
    end
    if not _M[name] then
        _M[name] = {}
        local err
        _M[name]['chash'], err = resty_chash:new(server_list)
        if not _M[name]['chash'] then
            log(ERR, 'chash init err:', err)
        end
        _M[name]['rr'], err = resty_rr:new(server_list)
        if not _M[name]['rr'] then
            log(ERR, 'rr init err:', err)
        end
        log(INFO, 'balancer init:' .. name)
    else
        _M[name]['chash']:reinit(server_list)
        log(INFO, 'chash reinit:' .. name)
        _M[name]['rr']:reinit(server_list)
        log(INFO, 'rr reinit:' .. name)
    end
end

local function spawn_healthcheck_from_file()
    for k, v in pairs(_M.data) do
        if type(v) == 'table' then
            local ok, err = spawn_healthcheck(k)
            if not ok then
                log(ERR, err)
            else
                log(INFO, 'start watch from file:', k)
            end
            hash_server(k)
            log(INFO, 'hash ' .. k .. ' due to start from file')
        end
    end
end

-- 查找可用的server,默认是rr算法
function _M.find(name, key, hash_method)
    if not _M[name] then
        log(ERR, 'upstream:', name, " haven't hash")
        return nil, 'upstream:' .. name .. " haven't hash"
    end
    local method = hash_method
    if not method or (method ~= 'chash' and method ~= 'rr') then
        log(ERR, 'invalid hash method:', method, ' use default hash method: rr')
        method = 'rr'
    end
    local hash = _M[name][method]
    if not hash then
        log(ERR, "can't find ", name, "'s hash handle:", method)
        return nil, "can't find " .. name .. "'s hash handle:" .. method
    end
    return hash:find(key)
end

local function watch(premature, conf, index)
    if premature then
        return
    end

    if ngx_worker_exiting() then
        return
    end

    if not _M.etcdc then
        local etcd = require('lrue.etcd')
        _M.etcdc = etcd.New(conf.etcd_host, conf.etcd_port)
    end

    local nextIndex
    if not index then
        -- Watch the change and update the data.
        -- First time to init all the upstreams.
        local data, err = _M.etcdc:Get(conf.etcd_key, {range_end = true})
        if err then
            log(ERR, err)
        else
            for k, v in pairs(data.kvs) do
                log(INFO, k .. ' : ' .. v)
                local name, b = separateKey(k)
                if name and b then
                    log(INFO, name .. '===>' .. b)
                    local value = decodeJson(v)
                    if b == 'healthcheck' then
                        set_healthcheck(name, value)
                    else
                        if not _M.data[name] or isTableEmpty(_M.data[name].servers) then
                            _M.data[name] = {
                                servers = {},
                                up_servers = {}
                            }
                            log(INFO, 'init _M.data[name]...')
                        end
                        local w = 1
                        local s = 'down'
                        if type(value) == 'table' then
                            if value.weight then
                                w = value.weight
                            end
                            if value.status then
                                s = value.status
                            end
                        end
                        local h, p, err = split_addr(b)
                        if not err then
                            log(INFO, h .. '...' .. p)
                            local tmp = {
                                host = h,
                                port = p,
                                weight = w,
                                status = s
                            }
                            table.insert(_M.data[name].servers, tmp)
                            if s == 'up' then
                                _M.data[name].up_servers[h .. ':' .. p] = w
                            end
                        else
                            log(ERR, err)
                        end
                    end
                end
            end

            _M.ready = true
            _M.data.version = data.revision
            dumpToFile(true)
            if _M.data.version then
                nextIndex = _M.data.version
                log(INFO, 'spawn healthcheck all upstream')
                spawn_healthcheck_from_file()
            end
        end
    else
        local change, err =
            _M.etcdc:Watch(
            conf.etcd_key,
            {
                range_end = true,
                start_revision = index
            }
        )
        if err then
            log(ERR, 'watch key: ', conf.etcd_key, ', error:', err)
        else
            for i = 1, #change.kvs do
                local name, b = separateKey(change.kvs[i].key)
                log(INFO, name .. '===>' .. b)
                if not name or not b then
                    log(ERR, 'separate key error: ' .. name .. '==>' .. b)
                    goto continue
                end

                if b == 'healthcheck' then
                    if change.kvs[i].action == 'delete' then
                        set_healthcheck(name, {})
                    else
                        set_healthcheck(name, decodeJson(change.kvs[i].value))
                    end
                else
                    local ok, value = pcall(decodeJson, change.kvs[i].value)
                    if not ok then
                        log(ERR, 'json decode failed.')
                        goto continue
                    end
                    local w = 1
                    local s = 'down'

                    if type(value) == 'table' then
                        if value.weight then
                            w = value.weight
                        end
                        if value.status then
                            s = value.status
                        end
                    end

                    local h, p, err = split_addr(b)
                    if err then
                        log(ERR, err)
                        goto continue
                    end

                    local bs = {
                        host = h,
                        port = p,
                        weight = w,
                        status = s
                    }

                    if change.kvs[i].action == 'delete' then
                        table.remove(_M.data[name].servers, indexOf(_M.data[name].servers, bs))
                        if _M.data[name].up_servers[h .. ':' .. p] then
                            _M.data[name].up_servers[h .. ':' .. p] = nil
                            log(INFO, 'DELETE up_servers [' .. name .. ']: ' .. h .. ':' .. p)
                            hash_server(name)
                            log(INFO, 'chash ' .. name .. ' due to DELETE ' .. h .. ':' .. p)
                        end
                        log(INFO, 'DELETE [' .. name .. ']: ' .. bs.host .. ':' .. bs.port)
                    elseif change.kvs[i].action == 'put' then
                        if not _M.data[name] then
                            _M.data[name] = {
                                servers = {bs},
                                up_servers = {}
                            }
                            log(INFO, 'ADD [' .. name .. ']: ' .. bs.host .. ':' .. bs.port)
                            if s == 'up' then
                                _M.data[name].up_servers[h .. ':' .. p] = w
                                log(INFO, 'ADD up_servers [' .. name .. ']: ' .. h .. ':' .. p)
                                hash_server(name)
                                log(INFO, 'hash ' .. name .. ' due to DIR ADD ' .. h .. ':' .. p)
                            end
                            ok, err = spawn_healthcheck(name)
                            if not ok then
                                log(ERR, err)
                            else
                                log(INFO, 'start healthcheck due to DIR ADD:' .. name)
                            end
                        else
                            local indexs = indexOf(_M.data[name].servers, bs)
                            if indexs == nil then
                                log(INFO, 'ADD [' .. name .. ']: ' .. bs.host .. ':' .. bs.port)
                                table.insert(_M.data[name].servers, bs)
                                if s == 'up' then
                                    _M.data[name].up_servers[h .. ':' .. p] = w
                                    log(INFO, 'ADD up_servers [' .. name .. ']: ' .. h .. ':' .. p)
                                    hash_server(name)
                                    log(INFO, 'hash ' .. name .. ' due to KEY ADD ' .. h .. ':' .. p)
                                end
                            else
                                _M.data[name].servers[indexs] = bs
                                log(
                                    INFO,
                                    'MODIFY [' ..
                                        name .. ']: ' .. bs.host .. ':' .. bs.port .. ' ' .. change.kvs[i].value
                                )
                                if s == 'up' then
                                    _M.data[name].up_servers[h .. ':' .. p] = w
                                    log(INFO, 'MODIFY ADD up_servers [' .. name .. ']: ' .. h .. ':' .. p)
                                    hash_server(name)
                                    log(INFO, 'hash ' .. name .. ' due to MODIFY ' .. h .. ':' .. p)
                                elseif s == 'down' then
                                    if _M.data[name].up_servers[h .. ':' .. p] then
                                        _M.data[name].up_servers[h .. ':' .. p] = nil
                                        log(INFO, 'MODIFY DELETE up_servers [' .. name .. ']: ' .. h .. ':' .. p)
                                        hash_server(name)
                                        log(INFO, 'hash ' .. name .. ' due to DELETE ' .. h .. ':' .. p)
                                    end
                                end
                            end
                        end
                    end
                end

                ::continue::
            end

            _M.data.version = change.revision
            nextIndex = _M.data.version + 1
            dumpToFile(false)
        end
    end

    -- Start the update cycle.
    local ok, err = ngx_timer_at(3, watch, conf, nextIndex)
    if not ok then
        log(ERR, 'Error start watch: ', err)
    end
end

-- 启动函数
function _M.init()
    local conf = require('lrue.config')
    if not conf then
        log(ERR, 'require config.lua error.')
        return
    end

    local nextIndex
    -- Load the upstreams from file
    if not _M.ready then
        _M.conf = conf
        local f_path = _M.conf.dump_file .. '_' .. _M.conf.etcd_key
        local file, err = io.open(f_path, 'r+')
        if file then
            local d = file:read('*a')
            local ok, data = pcall(decodeJson, d)
            if ok then
                _M.data = data
                file:close()
                _M.ready = true
                if _M.data.version then
                    nextIndex = _M.data.version
                    spawn_healthcheck_from_file()
                end
            end
        else
            log(ERR, err)
        end
    end

    -- Start the etcd watcher
    local ok, err = ngx_timer_at(0, watch, conf, nextIndex)
    if not ok then
        log(ERR, 'Error start watch: ' .. err)
    end
end

function _M.status()
    for k, v in pairs(_M.data) do
        if typeof.table(v) then
            if v['servers'] then
                for m, n in pairs(v['servers']) do
                    ngx.say('    ' .. n['host'] .. ':' .. n['port'] .. ' ' .. n['status'])
                end
            end
            ngx.say('healthcheck:', encodeJson(v['healthcheck']))
        end
    end
end

function _M.get_check_conf(upstream)
    if not _M.data[upstream] then
        return nil
    end
    if _M.data[upstream].healthcheck then
        return _M.data[upstream].healthcheck
    end
    return nil
end

function _M.get_primary_peers(upstream)
    if _M.data[upstream] then
        return _M.data[upstream].servers
    else
        return nil
    end
end

-- return error message
function _M.set_peer_down(upstream, server)
    log(INFO, 'set peer down.....')

    if not _M.etcdc then
        local etcd = require('lrue.etcd')
        _M.etcdc = etcd.New(_M.conf.etcd_host, _M.conf.etcd_port)
    end

    return _M.etcdc:Put(
        _M.conf.etcd_key .. '/' .. upstream .. '/' .. server.host .. ':' .. server.port,
        encodeJson(server)
    )
end

function _M.delete_peer(upstream, server)
    if not typeof.table(server) then
        return nil, 'server must be table'
    end
    return _M.etcdc:Delete(_M.conf.etcd_key .. '/' .. upstream .. '/' .. server.host .. ':' .. server.port)
end

function _M.delete_upstream(upstream)
    if not _M.data[upstream] then
        return upstream .. 'not exist'
    elseif length(_M.data[upstream].servers) > 0 then
        return upstream .. ' not empty'
    else
        return _M.etcdc:Deletes(_M.conf.etcd_key .. '/' .. upstream)
    end
end

function _M.add_peer(upstream, server)
    if not typeof.table(server) then
        return nil, 'server must be table'
    end
    return _M.set_peer_down(upstream, server)
end

function _M.healthcheck(upstream, health_conf)
    if not typeof.table(health_conf) then
        return nil, 'health_conf must be table'
    end

    local conf = _M.conf
    local check = _M.data[upstream].healthcheck
    for k, v in pairs(check) do
        if not health_conf[k] then
            health_conf[k] = v
        end
    end

    return _M.etcdc:Put(conf.etcd_key .. '/' .. upstream .. '/healthcheck', encodeJson(health_conf))
end

return _M
