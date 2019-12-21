--[[
etcd 操作封装类
注意：在etcd升到V3.5.0之后，将要使用 /v3/xxx 来代替 /v3beta/xxx

封装之后的接口返回的数据结构都如下：
local retData  = {
    revision = 1233,
    kvs = {
        key1 = value1,
        key2 = value2,
    }
}
--]]
local http = require('resty.http')
local cjson = require('cjson.safe')
local typeof = require('typeof')

local strSub = string.sub
local strByte = string.byte
local strChar = string.char

local encodeBase64 = ngx.encode_base64
local decodeBase64 = ngx.decode_base64
local decodeJson = cjson.decode
local encodeJson = cjson.encode

local _M = {}

local mt = {__index = _M}

function _M.New(host, port)
    if not typeof.string(host) then
        return nil, 'host must be a string'
    end

    if not typeof.uint(port) then
        return nil, 'port must be unsigned integer'
    end

    local endpoint = 'http://' .. host .. ':' .. port
    local apiPrefix = '/v3beta'

    return setmetatable(
        {
            host = host or '127.0.0.1',
            port = port or 2379,
            endpoint = endpoint,
            apiPrefix = apiPrefix,
            fullPrefix = endpoint .. apiPrefix
        },
        mt
    )
end

-- http 请求
local function requestUri(method, uri, args)
    if not method or not typeof.string(method) then
        return nil, 'method must be a string'
    end

    if not uri or not typeof.string(uri) then
        return nil, 'uri must be a string'
    end

    local body
    if args then
        body = encodeJson(args)
    end

    local httpc, err = http.new()
    if err then
        return nil, err
    end
    -- 单位 ms
    httpc:set_timeout(5000)

    local resp
    resp, err =
        httpc:request_uri(
        uri,
        {
            method = method,
            body = body
        }
    )
    if err then
        return nil, err
    end

    if resp.status >= 500 then
        return nil, 'invalid response code: ' .. resp.status
    end

    if resp.body then
        return decodeJson(resp.body)
    end

    return nil, 'invalid response body'
end

-- http 长连接
function _M:PostChunk(path, args)
    if not path or not typeof.string(path) then
        return nil, 'path must be a string'
    end

    -- ngx.log(ngx.INFO, 'path:', path, 'args:', args.create_request.key)

    local params
    if args then
        params = encodeJson(args)
    end

    local httpc, err = http.new()
    if err then
        return nil, err
    end

    httpc:set_timeout(100)
    local ok
    ok, err = httpc:connect(self.host, self.port)
    if not ok then
        return nil, err
    end

    local resp
    resp, err =
        httpc:request(
        {
            method = 'POST',
            path = path,
            body = params,
            header = {['Content-Type'] = 'application/x-www-form-urlencoded'}
        }
    )

    if not resp then
        return nil, err
    end

    if resp.status >= 300 then
        return nil, 'failed to watch data, response code: ' .. resp.status
    end

    local reader = resp.body_reader

    local retData
    local retErr = nil

    repeat
        local chunk, err = reader()
        if err then
            if err == 'timeout' then
                retErr = nil
            else
                retErr = err
            end
            break
        end

        -- 只需要最后的数据
        if chunk then
            retData = chunk
        end
    until not chunk

    httpc:close()

    return retData, retErr
end

local function rangeEnd(key)
    -- 最后一位的ASCII码要+1
    local lastChar = strChar(strByte(strSub(key, -1)) + 1)
    return strSub(key, 1, -2) .. lastChar
end

-- etcd version
function _M:Version()
    return requestUri('GET', self.endpoint .. '/version', '')
end

--[[
etcd put
参数：
key: string
value: string
opts: {
lease: int64
prev_kv: bool
ignore_value: bool
ignore_lease: bool
}
--]]
function _M:Put(key, value, opts)
    if not key or not typeof.string(key) or not typeof.string(value) then
        return 'parameter is nil'
    end

    opts = opts or {}

    local lease
    if opts.lease then
        lease = opts.lease and opts.lease or 0
    end

    local prev_kv
    if opts.prev_kv then
        prev_kv = opts.prev_kv and 'true' or 'false'
    end

    local ignore_value
    if opts.ignore_value then
        ignore_value = opts.ignore_value and 'true' or 'false'
    end

    local ignore_lease
    if opts.ignore_lease then
        ignore_lease = opts.ignore_lease and 'true' or 'false'
    end

    local bKey = encodeBase64(key)
    local bValue = encodeBase64(value)
    local args = {
        key = bKey,
        value = bValue,
        lease = lease,
        prev_kv = prev_kv,
        ignore_value = ignore_value,
        ignore_lease = ignore_lease
    }
    local _, err = requestUri('POST', self.fullPrefix .. '/kv/put', args)
    return err
    --{"header":{"cluster_id":"12585971608760269493","member_id":"13847567121247652255","revision":"2","raft_term":"3"}}
end

--[[
    opts:{
    range_end           : bool,
    limit               : int64,
    revision            : int64,
    sort_order          : int64,
    sort_target         : int64,
    serializable        : bool,
    keys_only           : bool,
    count_only          : bool,
    min_mod_revision    : int64,
    max_mod_revision    : int64,
    min_create_revision : int64,
    max_create_revision : int64
    }
    返回如下数据结构
    {
        revision = body.header.revision,
        kvs = {
            key = value,
        },
    }
--]]
function _M:Get(key, opts)
    if not key or not typeof.string(key) then
        return nil, 'parameter is nil'
    end

    opts = opts or {}

    local range_end
    if opts.range_end then
        range_end = encodeBase64(rangeEnd(key))
    end

    local limit
    if opts.limit then
        limit = opts.limit and opts.limit or 0
    end

    local revision
    if opts.revision then
        revision = opts.revision and opts.revision or 0
    end

    local sort_order
    if opts.sort_order then
        sort_order = opts.sort_order and opts.sort_order or 0
    end

    local sort_target
    if opts.sort_target then
        sort_target = opts.sort_target and opts.sort_target or 0
    end

    local serializable
    if opts.serializable then
        serializable = opts.serializable and 'true' or 'false'
    end

    local keys_only
    if opts.keys_only then
        keys_only = opts.keys_only and 'true' or 'false'
    end

    local count_only
    if opts.count_only then
        count_only = opts.count_only and 'true' or 'false'
    end

    local min_mod_revision
    if opts.min_mod_revision then
        min_mod_revision = opts.min_mod_revision or 0
    end

    local max_mod_revision
    if opts.max_mod_revision then
        max_mod_revision = opts.max_mod_revision or 0
    end

    local min_create_revision
    if opts.min_create_revision then
        min_create_revision = opts.min_create_revision or 0
    end

    local max_create_revision
    if opts.max_create_revision then
        max_create_revision = opts.max_create_revision or 0
    end

    local bKey = encodeBase64(key)
    local args = {
        key = bKey,
        range_end = range_end,
        limit = limit,
        revision = revision,
        sort_order = sort_order,
        sort_target = sort_target,
        serializable = serializable,
        keys_only = keys_only,
        count_only = count_only,
        min_mod_revision = min_mod_revision,
        max_mod_revision = max_mod_revision,
        min_create_revision = min_create_revision,
        max_create_revision = max_create_revision
    }

    local body, err = requestUri('POST', self.fullPrefix .. '/kv/range', args)
    if err then
        return nil, err
    end

    --[[
{
    "header": {
        "cluster_id": "12585971608760269493",
        "member_id": "13847567121247652255",
        "revision": "2",
        "raft_term": "3"
    },
    "kvs": [
        {
            "key": "Zm9v",
            "create_revision": "2",
            "mod_revision": "2",
            "version": "1",
            "value": "YmFy"
        }
    ],
    "count": "1"
}
--]]
    if not body.kvs then
        return nil, 'not found key'
    end

    local kvs = {}
    for i = 1, #body.kvs do
        kvs[decodeBase64(body.kvs[i].key)] = decodeBase64(body.kvs[i].value)
    end

    return {
        revision = body.header.revision,
        kvs = kvs
    }, nil
end

--[[
opts: {
    range_end: bool,
    prev_kv: bool,
}
--]]
function _M:Delete(key, opts)
    if not key or not typeof.string(key) then
        return nil, 'key must be a string'
    end

    opts = opts or {}

    local range_end
    if opts.range_end then
        range_end = encodeBase64(rangeEnd(key))
    end

    local prev_kv
    if opts.prev_kv then
        prev_kv = opts.prev_kv and 'true' or 'false'
    end

    local args = {
        key = encodeBase64(key),
        range_end = range_end,
        prev_kv = prev_kv
    }

    local body, err = requestUri('POST', self.fullPrefix .. '/kv/deleterange', args)
    if err then
        return nil, err
    end
    if body then
        return body.deleted, nil
    end
    return nil, 'deleted failed.'
    --[[
        {"header":{"cluster_id":"14841639068965178418","member_id":"10276657743932975437","revision":"29",
        "raft_term":"3"},"deleted":"1"}
    --]]
end

--[[
    入参：
opts:{
    range_end : bool,
    start_revision: int64,
    progress_notify: bool,
    filters: int64,
    prev_kv: bool
}
    返回的结构体
    {
        revision: string,
        kvs: []struct {
            key: string,
            value: string,
            action: string,
        }
    }
]]
function _M:Watch(key, opts)
    if not key or not typeof.string(key) then
        return nil, 'parameter is nil'
    end

    opts = opts or {}

    local range_end
    if opts.range_end then
        range_end = encodeBase64(rangeEnd(key))
    end

    local start_revision
    if opts.start_revision then
        start_revision = opts.start_revision and opts.start_revision or 0
    end

    local progress_notify
    if opts.progress_notify then
        progress_notify = opts.progress_notify and 'true' or 'false'
    end

    local filters
    if opts.filters then
        filters = opts.filters and opts.filters or 0
    end

    local prev_kv
    if opts.prev_kv then
        prev_kv = opts.prev_kv and 'true' or 'false'
    end

    local bKey = encodeBase64(key)
    local params = {
        create_request = {
            key = bKey,
            range_end = range_end,
            start_revision = start_revision,
            progress_notify = progress_notify,
            filters = filters,
            prev_kv = prev_kv
        }
    }

    --[[
      返回的结果示例：
      {"result":{"header":{"cluster_id":"12585971608760269493","member_id":"13847567121247652255",
      "revision":"2","raft_term":"2"},"events":[{"kv":{"key":"Zm9v","create_revision":"2","mod_revision":"2",
      "version":"1","value":"YmFy"}}]}}
    --]]
    local body, err = self:PostChunk(self.apiPrefix .. '/watch', params)
    if err then
        return nil, err
    end

    local ok, myData = pcall(decodeJson, body)
    if not ok then
        return nil, 'failed decode body'
    end

    local retData = {
        kvs = {}
    }

    retData.revision = myData.result.header.revision

    if myData.result.events then
        for i = 1, #myData.result.events do
            if myData.result.events[i]['kv'].mod_revision == myData.result.header.revision then
                local kv = {}
                kv.key = decodeBase64(myData.result.events[i]['kv'].key)
                if myData.result.events[i]['type'] == 'DELETE' then
                    kv.action = 'delete'
                    -- 这个是为了后面的json decode 不会失败
                    kv.value = ''
                else
                    kv.action = 'put'
                    kv.value = decodeBase64(myData.result.events[i]['kv'].value)
                end
                table.insert(retData.kvs, kv)
            end
        end
    end

    return retData, nil
end

return _M
