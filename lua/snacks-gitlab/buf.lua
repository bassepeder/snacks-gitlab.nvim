--- gitlab://host/group/repo/{mr,issue}/<iid> buffers
local Api = require("snacks-gitlab.api")
local Item = require("snacks-gitlab.item")
local Render = require("snacks-gitlab.render")

local M = {}

---@type table<string, snacks.gitlab.Item>
M.cache = {}

---@type table<number, table<number, snacks.gitlab.Thread>> buf -> line -> thread
M.threads = {}

---@param item snacks.gitlab.Item
function M.remember(item)
  M.cache[item.uri] = item
  return item
end

--- Fetches the item, its notes and (for MRs) approvals in parallel.
---@param ref {host:string, project:string, type:snacks.gitlab.Type, iid:number}
---@param cb fun(item?: snacks.gitlab.Item, details?: snacks.gitlab.Details)
function M.fetch(ref, cb)
  local pending, item, details = 0, nil, {} ---@type number, snacks.gitlab.Item?, snacks.gitlab.Details
  local failed = false
  local function done()
    pending = pending - 1
    if pending == 0 then
      vim.schedule(function()
        cb(not failed and item or nil, details)
      end)
    end
  end
  local function req(suffix, query, on_data, paginate)
    pending = pending + 1
    Api.request({
      host = ref.host,
      endpoint = Item.endpoint(ref, suffix),
      query = query,
      paginate = paginate,
    }, function(data)
      on_data(data)
      done()
    end)
  end
  req("", { with_labels_details = true }, function(data)
    if data then
      item = M.remember(Item.new(data, ref.type))
    else
      failed = true
    end
  end)
  req("/discussions", { per_page = 100 }, function(data)
    details.discussions = data or {}
  end, true)
  if ref.type == "mr" then
    req("/approvals", nil, function(data)
      details.approvals = data
    end)
  end
end

---@param buf number
---@param lines string[]
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---@param buf number
local function apply_wo(buf)
  local config = require("snacks-gitlab").config()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    for k, v in pairs(config.wo or {}) do
      vim.wo[win][k] = v
    end
  end
end

---@param buf number
---@param item snacks.gitlab.Item
local function keys(buf, item)
  local config = require("snacks-gitlab").config()
  local Actions = require("snacks-gitlab.actions")
  for _, km in pairs(config.keys or {}) do
    if km then
      vim.keymap.set(km.mode or "n", km[1], function()
        local cur = M.cache[item.uri] or item
        if km[2] == "gl_refresh" then
          return M.load(buf)
        end
        Actions.run(km[2], cur, { thread = M.thread_at(buf) })
      end, { buffer = buf, desc = km.desc, nowait = true })
    end
  end
end

--- (Re)loads a gitlab:// buffer
---@param buf number
function M.load(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local ref = Item.parse_uri(name)
  if not ref then
    Snacks.notify.error("Invalid GitLab buffer name: " .. name, { title = "GitLab" })
    return
  end
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].snacks_gitlab = ref

  local cached = M.cache[Item.uri(ref)]
  if cached then
    M.threads[buf] = nil
    set_lines(buf, (Render.lines(cached)))
  else
    set_lines(buf, { "Loading " .. name .. " …" })
  end
  apply_wo(buf)

  M.fetch(ref, function(item, details)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if not item then
      set_lines(buf, { "Failed to load " .. name })
      return
    end
    local lines, threads = Render.lines(item, details)
    set_lines(buf, lines)
    M.threads[buf] = threads
    keys(buf, item)
    apply_wo(buf)
  end)
end

--- Reload every open buffer showing this item
---@param item snacks.gitlab.Item
function M.refresh(item)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == item.uri then
      M.load(buf)
    end
  end
end

--- Thread under the cursor in a gitlab:// buffer
---@param buf? number
---@return snacks.gitlab.Thread?
function M.thread_at(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local threads = M.threads[buf]
  if not threads then
    return nil
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return nil
  end
  return threads[vim.api.nvim_win_get_cursor(win)[1]]
end

--- Item for the gitlab:// buffer, if any
---@param buf? number
function M.get(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ref = vim.b[buf].snacks_gitlab
  return ref and M.cache[Item.uri(ref)] or nil
end

local did_setup = false
function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  local group = vim.api.nvim_create_augroup("snacks.gitlab.buf", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "gitlab://*",
    group = group,
    callback = function(ev)
      M.load(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = "gitlab://*",
    group = group,
    callback = function(ev)
      vim.bo[ev.buf].modified = false
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    pattern = "gitlab://*",
    group = group,
    callback = function(ev)
      M.threads[ev.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    pattern = "gitlab://*",
    group = group,
    callback = function(ev)
      apply_wo(ev.buf)
    end,
  })
end

return M
