--- Normalizes GitLab REST objects (merge requests / issues) into picker items.
local M = {}

---@alias snacks.gitlab.Type "mr"|"issue"

---@class snacks.gitlab.Label
---@field name string
---@field color? string "#rrggbb"
---@field text_color? string

---@class snacks.gitlab.Item: snacks.picker.finder.Item
---@field type snacks.gitlab.Type
---@field host string
---@field project string full project path, e.g. "group/repo"
---@field iid number
---@field hash string "!12" or "#12"
---@field uri string gitlab://host/project/type/iid
---@field title string
---@field body string
---@field state string opened|closed|merged|locked
---@field status string state used for icons (open|closed|merged|draft)
---@field draft boolean
---@field author? string username
---@field labels snacks.gitlab.Label[]
---@field url string web url
---@field updated? number unix time
---@field created? number unix time
---@field raw table original API object

--- Parses an ISO 8601 timestamp with offset (GitLab style) into unix time.
---@param s? string
function M.ts(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, sec, rest = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*(.*)$")
  if not y then
    return nil
  end
  local offset = 0
  local sign, oh, om = rest:match("^([%+%-])(%d%d):?(%d%d)$")
  if sign then
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec, isdst = false })
  -- os.time interprets the table as local time; convert to UTC
  local now = os.time()
  local utc = os.date("!*t", now) --[[@as osdate]]
  utc.isdst = false
  local local_offset = os.difftime(now, os.time(utc))
  return t + local_offset - offset
end

--- host + project path from a web url
---@param url string
function M.parse_url(url)
  local host, path = url:match("^https?://([^/]+)/(.-)/%-/")
  return host, path
end

---@param raw table
---@param type snacks.gitlab.Type
function M.new(raw, type)
  local host, project = M.parse_url(raw.web_url or "")
  local labels = {} ---@type snacks.gitlab.Label[]
  for _, l in ipairs(raw.labels or {}) do
    labels[#labels + 1] = _G.type(l) == "table" and l or { name = l }
  end
  local state = raw.state or "opened"
  local draft = raw.draft == true or raw.work_in_progress == true
  local status = (state == "opened" or state == "locked") and (draft and "draft" or "open") or state
  local sigil = type == "mr" and "!" or "#"
  ---@type snacks.gitlab.Item
  local item = {
    type = type,
    host = host,
    project = project,
    iid = raw.iid,
    hash = sigil .. raw.iid,
    title = raw.title or "",
    body = (raw.description or ""):gsub("\r\n", "\n"),
    state = state,
    status = status,
    draft = draft,
    author = raw.author and raw.author.username or nil,
    labels = labels,
    url = raw.web_url,
    updated = M.ts(raw.updated_at),
    created = M.ts(raw.created_at),
    raw = raw,
  }
  item.uri = M.uri(item)
  item.file = item.uri
  item.text = table.concat({
    item.hash,
    item.title,
    item.author and ("@" .. item.author) or "",
    table.concat(
      vim.tbl_map(function(l)
        return l.name
      end, labels),
      " "
    ),
  }, " ")
  return item
end

---@param item {host:string, project:string, type:string, iid:number}
function M.uri(item)
  return ("gitlab://%s/%s/%s/%s"):format(item.host, item.project, item.type, item.iid)
end

---@param uri string
---@return {host:string, project:string, type:snacks.gitlab.Type, iid:number}?
function M.parse_uri(uri)
  local host, project, type, iid = uri:match("^gitlab://([^/]+)/(.+)/(%a+)/(%d+)$")
  if not host or (type ~= "mr" and type ~= "issue") then
    return nil
  end
  return { host = host, project = project, type = type, iid = tonumber(iid) }
end

--- REST endpoint for a single item
---@param item {project:string, type:string, iid:number}
---@param suffix? string
function M.endpoint(item, suffix)
  local Api = require("snacks-gitlab.api")
  local kind = item.type == "mr" and "merge_requests" or "issues"
  return ("projects/%s/%s/%d%s"):format(Api.project(item.project), kind, item.iid, suffix or "")
end

return M
