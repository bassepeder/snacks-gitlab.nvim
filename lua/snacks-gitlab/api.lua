--- Thin wrapper around `glab api` (REST v4).
--- All requests go through `glab`, so auth, self-hosted hosts and tokens
--- are handled by `glab auth login`.
local M = {}

---@class snacks.gitlab.Request
---@field endpoint string REST path, e.g. "projects/:id/merge_requests"
---@field method? "GET"|"POST"|"PUT"|"DELETE"
---@field query? table<string, string|number|boolean|nil>
---@field body? table JSON body (sent with --input -)
---@field host? string GitLab hostname (defaults to the host of the repo in cwd)
---@field paginate? boolean
---@field cwd? string
---@field notify? boolean show errors (default true)
---@field raw? boolean return the response body as text instead of decoding JSON

---@param s any
function M.urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

--- Project reference usable in an endpoint.
--- `nil` means "the project of the git repo in cwd" (glab's `:id` placeholder).
---@param project? string full path, e.g. "group/sub/repo"
function M.project(project)
  return project and M.urlencode(project) or ":id"
end

---@param query? table<string, any>
local function encode_query(query)
  local parts = {} ---@type string[]
  for k, v in pairs(query or {}) do
    if v ~= nil and v ~= "" and v ~= false then
      parts[#parts + 1] = M.urlencode(k) .. "=" .. M.urlencode(v)
    end
  end
  table.sort(parts)
  return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

---@param req snacks.gitlab.Request
function M.args(req)
  local args = { "glab", "api" }
  if req.host then
    vim.list_extend(args, { "--hostname", req.host })
  end
  if req.method and req.method ~= "GET" then
    vim.list_extend(args, { "-X", req.method })
  end
  if req.paginate then
    args[#args + 1] = "--paginate"
  end
  if req.body then
    vim.list_extend(args, { "--input", "-" })
  end
  args[#args + 1] = req.endpoint .. encode_query(req.query)
  return args
end

---@param req snacks.gitlab.Request
---@param stderr string
local function report(req, stderr)
  if req.notify == false then
    return
  end
  vim.schedule(function()
    local msg = vim.trim(stderr or "")
    Snacks.notify.error(
      ("`glab api %s %s` failed\n\n%s"):format(req.method or "GET", req.endpoint, msg ~= "" and msg or "(no output)"),
      { title = "GitLab" }
    )
  end)
end

--- Async request. `cb(data, err)` runs in a fast event context.
---@param req snacks.gitlab.Request
---@param cb fun(data?: any, err?: string)
---@return vim.SystemObj
function M.request(req, cb)
  local args = M.args(req)
  return vim.system(args, {
    text = true,
    cwd = req.cwd,
    stdin = req.body and vim.json.encode(req.body) or nil,
  }, function(res)
    if res.code ~= 0 then
      report(req, res.stderr ~= "" and res.stderr or res.stdout)
      return cb(nil, res.stderr)
    end
    local out = res.stdout or ""
    if req.raw then
      return cb(out)
    end
    if vim.trim(out) == "" then
      return cb({})
    end
    local ok, data = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
    if not ok then
      -- --paginate concatenates JSON arrays: "[...][...]"
      ok, data = pcall(vim.json.decode, "[" .. out:gsub("%]%s*%[", ",") .. "]")
      data = ok and data[1] or nil
    end
    if not ok then
      report(req, "Invalid JSON response:\n" .. out:sub(1, 500))
      return cb(nil, "invalid json")
    end
    cb(data)
  end)
end

--- Request from inside a Snacks picker async context (finders).
--- Suspends the coroutine until the request completes.
---@async
---@param req snacks.gitlab.Request
function M.await(req)
  local Async = require("snacks.picker.util.async")
  local async = Async.running()
  if not async then
    return M.sync(req)
  end
  local ret, err, done ---@type any, string?, boolean
  local proc = M.request(req, function(data, e)
    ret, err, done = data, e, true
    async:resume()
  end)
  async:on("abort", function()
    if not done then
      proc:kill("sigterm")
    end
  end)
  while not done do
    async:suspend()
  end
  return ret, err
end

--- Blocking request (use sparingly).
---@param req snacks.gitlab.Request
function M.sync(req)
  local ret, err, done ---@type any, string?, boolean
  M.request(req, function(data, e)
    ret, err, done = data, e, true
  end):wait()
  vim.wait(1000, function()
    return done
  end)
  return ret, err
end

--- Run a `glab` subcommand from inside a Snacks async context and return its stdout.
---@async
---@param args string[]
---@param opts? {cwd?:string}
---@return string? stdout, string? err
function M.glab_await(args, opts)
  local Async = require("snacks.picker.util.async")
  local async = assert(Async.running(), "glab_await needs an async context")
  local ok, out, stdout, done ---@type boolean, string, string, boolean
  M.glab(args, opts, function(o, text, so)
    ok, out, stdout, done = o, text, so, true
    async:resume()
  end)
  while not done do
    async:suspend()
  end
  return ok and stdout or nil, not ok and out or nil
end

--- Run an arbitrary `glab` subcommand (e.g. `mr checkout`).
---@param args string[]
---@param opts? {cwd?:string}
---@param cb? fun(ok:boolean, out:string, stdout:string) `out` is stdout+stderr, trimmed
function M.glab(args, opts, cb)
  opts = opts or {}
  return vim.system(vim.list_extend({ "glab" }, args), { text = true, cwd = opts.cwd }, function(res)
    local out = vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
    if cb then
      cb(res.code == 0, out, res.stdout or "")
    end
  end)
end

return M
