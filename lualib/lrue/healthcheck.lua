local dyups = require("lrue.dyups")

local stream_sock = ngx.socket.tcp
local sub = string.sub
local re_find = ngx.re.find
local new_timer = ngx.timer.at
local tonumber = tonumber
local ipairs = ipairs
local ceil = math.ceil
local spawn = ngx.thread.spawn
local wait = ngx.thread.wait

local log = ngx.log
local ERR = ngx.ERR
local INFO = ngx.INFO

local _M = {_VERSION = "0.05"}

if not ngx.config or not ngx.config.ngx_lua_version or ngx.config.ngx_lua_version < 9005 then
    log(ERR, "ngx_lua 0.9.5+ required")
end

local upstream_checker_statuses = {}

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function(narr, nrec)
        return {}
    end
end

local function gen_peer_key(prefix, u, is_backup, id)
    if is_backup then
        return prefix .. u .. ":b" .. id
    end
    return prefix .. u .. ":p" .. id
end

local function get_primary_peers(u)
    local res, err = dyups.get_primary_peers(u)
    if not res then
        log(ERR, "get primary peers error: ", err, " u: ", u)
        return nil
    end
    for _, v in pairs(res) do
        if v["status"] == "down" then
            v["down"] = true
        else
            v["down"] = false
        end
    end
    return res
end

local function set_peer_down(ctx, is_backup, id, value)
    local peers = ctx.primary_peers
    local host = peers[id + 1]["host"]
    local port = peers[id + 1]["port"]
    local weight = peers[id + 1]["weight"]
    --local current_weight = peers[id+1]["current_weight"]
    local server
    if value then
        server = {
            host = host,
            port = port,
            weight = weight,
            status = "down"
        }
    else
        server = {
            host = host,
            port = port,
            weight = weight,
            status = "up"
        }
    end

    local err = dyups.set_peer_down(ctx.upstream, server)
    if err then
        log(ERR, "set peer down error:", err)
        return false, err
    end
    return true
end

local function set_peer_down_globally(ctx, is_backup, id, value)
    local u = ctx.upstream
    local dict = ctx.dict

    local ok, err = set_peer_down(ctx, is_backup, id, value)
    if not ok then
        log(ERR, "failed to set peer down: ", err)
        return
    end

    if not ctx.new_version then
        ctx.new_version = true
    end

    local key = gen_peer_key("d:", u, is_backup, id)
    ok, err = dict:set(key, value)
    if not ok then
        log(ERR, "failed to set peer down state: ", err)
    end
end

local function peer_fail(ctx, is_backup, id, peer)
    log(INFO, "peer ", peer.host, ":", peer.port, " was checked to be not ok")

    local u = ctx.upstream
    local dict = ctx.dict

    local key = gen_peer_key("nok:", u, is_backup, id)
    local fails, err = dict:get(key)
    if not fails then
        if err then
            log(ERR, "failed to get peer nok key: ", err)
            return
        end
        fails = 1

        -- below may have a race condition, but it is fine for our
        -- purpose here.
        local ok, err = dict:set(key, 1)
        if not ok then
            log(ERR, "failed to set peer nok key: ", err)
        end
    else
        fails = fails + 1
        local ok, err = dict:incr(key, 1)
        if not ok then
            log(ERR, "failed to incr peer nok key: ", err)
        end
    end

    if fails == 1 then
        key = gen_peer_key("ok:", u, is_backup, id)
        local succ, err = dict:get(key)
        if not succ or succ == 0 then
            if err then
                log(ERR, "failed to get peer ok key: ", err)
                return
            end
        else
            local ok, err = dict:set(key, 0)
            if not ok then
                log(ERR, "failed to set peer ok key: ", err)
            end
        end
    end

    if not peer.down and fails >= ctx.fall then
        log(ERR, "peer ", peer.host, ":", peer.port, " is turned down after ", fails, " failure(s)")
        peer.down = true
        set_peer_down_globally(ctx, is_backup, id, true)
    end
end

local function peer_ok(ctx, is_backup, id, peer)
    log(INFO, "peer ", peer.host, ":", peer.port, " was checked to be ok")

    local u = ctx.upstream
    local dict = ctx.dict

    local key = gen_peer_key("ok:", u, is_backup, id)
    local succ, err = dict:get(key)
    if not succ then
        if err then
            log(ERR, "failed to get peer ok key: ", err)
            return
        end
        succ = 1

        -- below may have a race condition, but it is fine for our
        -- purpose here.
        local ok, err = dict:set(key, 1)
        if not ok then
            log(ERR, "failed to set peer ok key: ", err)
        end
    else
        succ = succ + 1
        local ok, err = dict:incr(key, 1)
        if not ok then
            log(ERR, "failed to incr peer ok key: ", err)
        end
    end

    if succ == 1 then
        key = gen_peer_key("nok:", u, is_backup, id)
        local fails, err = dict:get(key)
        if not fails or fails == 0 then
            if err then
                log(ERR, "failed to get peer nok key: ", err)
                return
            end
        else
            local ok, err = dict:set(key, 0)
            if not ok then
                log(ERR, "failed to set peer nok key: ", err)
            end
        end
    end

    log(INFO, "peer ok status:", peer.name, ":", peer.down, " succ:", succ)
    if peer.down and succ >= ctx.rise then
        log(INFO, "peer ", peer.host, ":", peer.port, " is turned up after ", succ, " success(es)")
        peer.down = nil
        set_peer_down_globally(ctx, is_backup, id, nil)
    end
end

-- shortcut error function for check_peer()
local function peer_error(ERR, ctx, is_backup, id, peer, ...)
    if not peer.down then
        log(ERR, ...)
    end
    peer_fail(ctx, is_backup, id, peer)
end

local function check_peer(ctx, id, peer, is_backup)
    local u = ctx.upstream
    local ok, err
    local name = peer.name or peer.host .. ":" .. peer.port
    local statuses = ctx.statuses
    local req = ctx.http_req

    local sock, err = stream_sock()
    if not sock then
        log(ERR, "failed to create stream socket: ", err)
        return
    end

    sock:settimeout(ctx.timeout)

    if peer.host then
        ok, err = sock:connect(peer.host, peer.port)
    else
        ok, err = sock:connect(name)
    end
    if not ok then
        if not peer.down then
            log(ERR, "failed to connect to ", name, ": ", err)
        end
        return peer_fail(ctx, is_backup, id, peer)
    end

    local bytes, err = sock:send(req)
    if not bytes then
        return peer_error(ERR, ctx, is_backup, id, peer, "failed to send request to ", name, ": ", err)
    end

    local status_line, err = sock:receive()
    if not status_line then
        peer_error(ERR, ctx, is_backup, id, peer, "failed to receive status line from ", name, ": ", err)
        if err == "timeout" then
            sock:close() -- timeout errors do not close the socket.
        end
        return
    end

    if statuses then
        local from, to, err = re_find(status_line, [[^HTTP/\d+\.\d+\s+(\d+)]], "joi", nil, 1)
        if not from then
            peer_error(ERR, ctx, is_backup, id, peer, "bad status line from ", name, ": ", status_line)
            sock:close()
            return
        end

        local status = tonumber(sub(status_line, from, to))
        if not statuses[status] then
            peer_error(ERR, ctx, is_backup, id, peer, "bad status code from ", name, ": ", status)
            sock:close()
            return
        end
    end

    peer_ok(ctx, is_backup, id, peer)
    sock:close()
end

local function check_peer_range(ctx, from, to, peers, is_backup)
    for i = from, to do
        check_peer(ctx, i - 1, peers[i], is_backup)
    end
end

local function check_peers(ctx, peers, is_backup)
    local n = #peers
    if n == 0 then
        return
    end

    local concur = ctx.concurrency
    if concur <= 1 then
        -- use the current "light thread" to run the last task
        for i = 1, n do
            check_peer(ctx, i - 1, peers[i], is_backup)
        end
    else
        local threads
        local nthr

        if n <= concur then
            nthr = n - 1
            threads = new_tab(nthr, 0)
            for i = 1, nthr do
                log(INFO, "spawn a thread checking ", is_backup and "backup" or "primary", " peer ", i - 1)

                threads[i] = spawn(check_peer, ctx, i - 1, peers[i], is_backup)
            end

            log(INFO, "check ", is_backup and "backup" or "primary", " peer ", n - 1)

            check_peer(ctx, n - 1, peers[n], is_backup)
        else
            local group_size = ceil(n / concur)
            nthr = ceil(n / group_size) - 1

            threads = new_tab(nthr, 0)
            local from = 1
            local rest = n
            for i = 1, nthr do
                local to
                if rest >= group_size then
                    rest = rest - group_size
                    to = from + group_size - 1
                else
                    rest = 0
                    to = from + rest - 1
                end

                log(
                    INFO,
                    "spawn a thread checking ",
                    is_backup and "backup" or "primary",
                    " peers ",
                    from - 1,
                    " to ",
                    to - 1
                )

                threads[i] = spawn(check_peer_range, ctx, from, to, peers, is_backup)
                from = from + group_size
                if rest == 0 then
                    break
                end
            end
            if rest > 0 then
                local to = from + rest - 1

                log(INFO, "check ", is_backup and "backup" or "primary", " peers ", from - 1, " to ", to - 1)

                check_peer_range(ctx, from, to, peers, is_backup)
            end
        end

        if nthr and nthr > 0 then
            for i = 1, nthr do
                local t = threads[i]
                if t then
                    wait(t)
                end
            end
        end
    end
end

local function upgrade_peers_version(ctx, peers, is_backup)
    local dict = ctx.dict
    local u = ctx.upstream
    local n = #peers
    for i = 1, n do
        local peer = peers[i]
        local id = i - 1
        local key = gen_peer_key("d:", u, is_backup, id)
        local down = false
        local res, err = dict:get(key)
        if not res then
            if err then
                log(ERR, "failed to get peer down state: ", err)
            end
        else
            down = true
        end
        if (peer.down and not down) or (not peer.down and down) then
            local ok, err = set_peer_down(ctx, is_backup, id, down)
            if not ok then
                -- update our cache too
                log(ERR, "failed to set peer down: ", err)
            else
                peer.down = down
            end
        end
    end
end

local function check_peers_updates(ctx)
    local dict = ctx.dict
    local u = ctx.upstream
    local key = "v:" .. u
    local ver, err = dict:get(key)
    if not ver then
        if err then
            log(ERR, "failed to get peers version: ", err)
            return
        end

        if ctx.version > 0 then
            ctx.new_version = true
        end
    elseif ctx.version < ver then
        log(INFO, "upgrading peers version to ", ver)
        ctx.version = ver
    end
end

local function get_lock(ctx)
    local dict = ctx.dict
    local key = "l:" .. ctx.upstream

    -- the lock is held for the whole interval to prevent multiple
    -- worker processes from sending the test request simultaneously.
    -- here we substract the lock expiration time by 1ms to prevent
    -- a race condition with the next timer event.
    local ok, err = dict:add(key, true, ctx.interval - 0.001)
    if not ok then
        if err == "exists" then
            return false
        end
        log(ERR, 'failed to add key "', key, '": ', err)
        return false
    end
    return true
end

local function do_check(ctx)
    log(INFO, "healthcheck: run a check cycle")

    check_peers_updates(ctx)

    if get_lock(ctx) then
        check_peers(ctx, ctx.primary_peers, false)
    --check_peers(ctx, ctx.backup_peers, true)
    end

    if ctx.new_version then
        local key = "v:" .. ctx.upstream
        local dict = ctx.dict

        log(INFO, "publishing peers version ", ctx.version + 1)

        dict:add(key, 0)
        local new_ver, err = dict:incr(key, 1)
        if not new_ver then
            log(ERR, "failed to publish new peers version: ", err)
        end

        ctx.version = new_ver
        ctx.new_version = nil
    end
end

local function update_upstream_checker_status(upstream, success)
    local cnt = upstream_checker_statuses[upstream]
    if not cnt then
        cnt = 0
    end

    if success then
        cnt = cnt + 1
    else
        cnt = cnt - 1
    end

    upstream_checker_statuses[upstream] = cnt
end

local function preprocess_peers(peers)
    local n = #peers
    for i = 1, n do
        local p = peers[i]
        local name = p.name

        if name then
            local from, to, err = re_find(name, [[^(.*):\d+$]], "jo", nil, 1)
            if from then
                p.host = sub(name, 1, to)
                p.port = tonumber(sub(name, to + 2))
            end
        end
    end
    return peers
end

local check
check = function(premature, ctx)
    if premature then
        return
    end

    local ppeers, err = get_primary_peers(ctx.upstream)
    if not ppeers then
        log(ERR, "failed to get primary peers: ", err)
        return
    end

    local primary_peers = preprocess_peers(ppeers)
    ctx.primary_peers = primary_peers

    local opts = dyups.get_check_conf(ctx.upstream)

    if opts.http_req and opts.http_req ~= "" then
        ctx.http_req = opts.http_req
    end

    if opts.timeout then
        ctx.timeout = opts.timeout
    end

    if opts.interval then
        local interval = opts.interval / 1000
        if interval < 0.002 then
            ctx.interval = 0.002
        else
            ctx.interval = interval
        end
    end
    if opts.valid_statuses then
        local valid_statuses = opts.valid_statuses
        local statuses = new_tab(0, #valid_statuses)
        for _, status in ipairs(valid_statuses) do
            statuses[status] = true
        end
        ctx.statuses = statuses
    end

    if opts.concurrency then
        ctx.concurrency = opts.concurrency
    end

    if opts.fall then
        ctx.fall = opts.fall
    end

    if opts.rise then
        ctx.rise = opts.rise
    end

    local ok, err = pcall(do_check, ctx)
    if not ok then
        log(ERR, "failed to run healthcheck cycle: ", err)
    end

    ok, err = new_timer(ctx.interval, check, ctx)
    if not ok then
        if err ~= "process exiting" then
            log(ERR, "failed to create timer: ", err)
        end
        -- update_upstream_checker_status(ctx.upstream, false)
        return
    end
end

function _M.spawn_checker(opts)
    local typ = opts.type
    if not typ then
        return nil, '"type" option required'
    end

    if typ ~= "http" then
        return nil, 'only "http" type is supported right now'
    end

    local http_req = opts.http_req
    if not http_req then
        return nil, '"http_req" option required'
    end

    local timeout = opts.timeout
    if not timeout then
        timeout = 1000
    end

    local interval = opts.interval
    if not interval then
        interval = 1 -- minimum 2ms
    else
        interval = interval / 1000
        if interval < 0.002 then
            interval = 0.002
        end
    end

    local valid_statuses = opts.valid_statuses
    local statuses
    if valid_statuses then
        statuses = new_tab(0, #valid_statuses)
        for _, status in ipairs(valid_statuses) do
            --log(ERR,"found good status ", status)
            statuses[status] = true
        end
    end

    -- log(ERR,"interval: ", interval)

    local concur = opts.concurrency
    if not concur then
        concur = 1
    end

    local fall = opts.fall
    if not fall then
        fall = 5
    end

    local rise = opts.rise
    if not rise then
        rise = 2
    end

    -- local shm = opts.shm
    -- if not shm then
    --     return nil, '"shm" option required'
    -- end

    -- local dict = shared[shm]
    local dict = opts.dict
    if not dict then
        return nil, "dict not found"
    end

    local u = opts.upstream
    if not u then
        return nil, "no upstream specified"
    end

    -- local ppeers, err = get_primary_peers(u)
    -- if not ppeers then
    --    return nil, "failed to get primary peers: " .. err
    -- end

    -- local bpeers, err = get_backup_peers(u)
    -- if not bpeers then
    --    return nil, "failed to get backup peers: " .. err
    -- end

    local ctx = {
        upstream = u,
        --primary_peers = preprocess_peers(ppeers),
        --backup_peers = preprocess_peers(bpeers),
        http_req = http_req,
        timeout = timeout,
        interval = interval,
        dict = dict,
        fall = fall,
        rise = rise,
        statuses = statuses,
        version = 0,
        concurrency = concur
    }

    local ok, err = new_timer(0, check, ctx)
    if not ok then
        return nil, "failed to create timer: " .. err
    end

    update_upstream_checker_status(u, true)

    return true
end

local function gen_peers_status_log(ERR, peers, bits, idx)
    local nPeers = #peers
    for i = 1, nPeers do
        local peer = peers[i]
        bits[idx] = "        "
        bits[idx + 1] = peer.name
        if peer.down then
            bits[idx + 2] = " DOWN\n"
        else
            bits[idx + 2] = " up\n"
        end
        idx = idx + 3
    end
    return idx
end

function _M.status_page()
    -- generate an HTML page
    local bits = new_tab(20, 0)
    local u = "conference"
    local idx = 1
    bits[idx] = "Upstream "
    bits[idx + 1] = u
    bits[idx + 2] = "\n    Primary Peers\n"
    idx = idx + 3

    local peers, err = get_primary_peers()
    if not peers then
        return "failed to get primary peers in upstream " .. u .. ": " .. err
    end

    idx = gen_peers_status_log(ERR, peers, bits, idx)

    return bits
end

return _M
