--- Actions on merge requests and issues.
--- Every action is `action(item, ctx)`; `ctx.picker` is set when run from a picker.
local Api = require("snacks-gitlab.api")
local Buf = require("snacks-gitlab.buf")
local Item = require("snacks-gitlab.item")

local M = {}

---@class snacks.gitlab.action.ctx
---@field picker? snacks.Picker
---@field items? snacks.gitlab.Item[]
---@field action? snacks.picker.Action
---@field thread? snacks.gitlab.Thread discussion under the cursor (gitlab:// buffers)

---@class snacks.gitlab.Action
---@field desc string
---@field icon? string
---@field type? snacks.gitlab.Type only for this type
---@field priority? number higher sorts first in the actions menu
---@field hidden? boolean not shown in the actions menu
---@field needs_thread? boolean only works with the cursor on a comment thread
---@field enabled? fun(item: snacks.gitlab.Item, ctx: snacks.gitlab.action.ctx): boolean
---@field action fun(item: snacks.gitlab.Item, ctx: snacks.gitlab.action.ctx)

local function icons()
  return require("snacks-gitlab").config().icons
end

---@param item snacks.gitlab.Item
local function is_open(item)
  return item.state == "opened" or item.state == "locked"
end

---@param item snacks.gitlab.Item
local function label(item)
  return (item.type == "mr" and "MR " or "issue ") .. item.hash
end

--- Re-fetch after a mutation: refresh open buffers and the picker
---@param item snacks.gitlab.Item
---@param ctx snacks.gitlab.action.ctx
---@param data? table updated API object, if the endpoint returned one
local function updated(item, ctx, data)
  vim.schedule(function()
    if type(data) == "table" and data.iid then
      Buf.remember(Item.new(data, item.type))
    end
    Buf.refresh(item)
    if ctx.picker and not ctx.picker.closed then
      ctx.picker:find({ refresh = true })
    end
  end)
end

--- Performs a REST call on the item and reports the outcome
---@param item snacks.gitlab.Item
---@param ctx snacks.gitlab.action.ctx
---@param req {method:string, suffix?:string, body?:table, success:string}
local function call(item, ctx, req)
  Api.request({
    host = item.host,
    method = req.method,
    endpoint = Item.endpoint(item, req.suffix),
    body = req.body,
  }, function(data, err)
    if err then
      return
    end
    vim.schedule(function()
      Snacks.notify.info(req.success, { title = "GitLab" })
    end)
    updated(item, ctx, data)
  end)
end

---@param msg string
---@param fn fun()
local function confirm(msg, fn)
  vim.ui.select({ "Yes", "No" }, { prompt = msg }, function(choice)
    if choice == "Yes" then
      fn()
    end
  end)
end

--- Opens a markdown input window. `<c-s>` submits, `q` cancels.
---@param opts {title:string, text?:string, on_submit:fun(text:string)}
function M.input(opts)
  local config = require("snacks-gitlab").config()
  Snacks.win({
    position = "float",
    width = 0.6,
    height = config.scratch.height or 15,
    border = "rounded",
    title = " " .. icons().logo .. opts.title .. " ",
    title_pos = "center",
    footer_keys = { "<c-s>", "q" },
    ft = "markdown",
    text = opts.text or "",
    bo = { buftype = "nofile", bufhidden = "wipe", swapfile = false },
    wo = { wrap = true, linebreak = true, conceallevel = 0 },
    keys = {
      submit = {
        "<c-s>",
        function(win)
          local text = win:text()
          vim.cmd.stopinsert()
          win:close()
          opts.on_submit(text)
        end,
        desc = "Submit",
        mode = { "n", "i" },
      },
      q = "close",
    },
    on_win = function()
      vim.schedule(function()
        vim.cmd.startinsert()
      end)
    end,
  })
end

---@type table<string, snacks.gitlab.Action>
M.actions = {}

M.actions.gl_actions = {
  desc = "Show available actions",
  hidden = true,
  action = function(item, ctx)
    M.menu(item, ctx)
  end,
}

M.actions.gl_open = {
  desc = "Open in buffer",
  icon = "\u{f15c} ",
  priority = 100,
  action = function(item, ctx)
    if ctx.picker then
      ctx.picker:close()
    end
    vim.schedule(function()
      vim.cmd.edit(vim.fn.fnameescape(item.uri))
    end)
  end,
}

M.actions.gl_diff = {
  desc = "View diff",
  icon = "\u{f440} ",
  type = "mr",
  priority = 95,
  action = function(item, ctx)
    if ctx.picker and not ctx.picker.closed then
      ctx.picker:close()
    end
    vim.schedule(function()
      require("snacks-gitlab.diff").open(item)
    end)
  end,
}

M.actions.gl_browse = {
  desc = "Open in web browser",
  icon = "\u{f0ac} ",
  priority = 90,
  action = function(item)
    vim.ui.open(item.url)
  end,
}

M.actions.gl_yank = {
  desc = "Copy URL",
  icon = "\u{f0c5} ",
  priority = 80,
  action = function(item, ctx)
    local urls = vim.tbl_map(function(it)
      return it.url
    end, ctx.items or { item })
    local text = table.concat(urls, "\n")
    vim.fn.setreg(vim.v.register, text)
    vim.fn.setreg("+", text)
    Snacks.notify.info("Copied " .. text, { title = "GitLab" })
  end,
}

M.actions.gl_checkout = {
  desc = "Check out source branch",
  icon = icons().branch,
  type = "mr",
  priority = 70,
  enabled = is_open,
  action = function(item, ctx)
    if ctx.picker then
      ctx.picker:close()
    end
    Snacks.notify.info(("Checking out %s …"):format(item.raw.source_branch), { title = "GitLab" })
    Api.glab({ "mr", "checkout", tostring(item.iid), "-R", (item.url:gsub("/%-/merge_requests/.*$", "")) }, nil,
      function(ok, out)
        vim.schedule(function()
          if ok then
            Snacks.notify.info(("Checked out `%s`"):format(item.raw.source_branch), { title = "GitLab" })
            vim.cmd.checktime()
          else
            Snacks.notify.error("Checkout failed:\n" .. out, { title = "GitLab" })
          end
        end)
      end)
  end,
}

M.actions.gl_comment = {
  desc = "Add comment",
  icon = "\u{f27b} ",
  priority = 60,
  action = function(item, ctx)
    M.input({
      title = "Comment on " .. label(item),
      on_submit = function(body)
        if not body:find("%S") then
          return
        end
        call(item, ctx, {
          method = "POST",
          suffix = "/notes",
          body = { body = body },
          success = "Commented on " .. label(item),
        })
      end,
    })
  end,
}

M.actions.gl_edit = {
  desc = "Edit title and description",
  icon = "\u{f044} ",
  priority = 50,
  action = function(item, ctx)
    M.input({
      title = "Edit " .. label(item),
      text = ("---\ntitle: %s\n---\n\n%s"):format(item.title, item.body),
      on_submit = function(text)
        local title, body = text:match("^%-%-%-\ntitle:%s*(.-)%s*\n%-%-%-\n%s*(.*)$")
        if not title or title == "" then
          Snacks.notify.error("Keep the `title:` front matter at the top", { title = "GitLab" })
          return
        end
        call(item, ctx, {
          method = "PUT",
          body = { title = title, description = body },
          success = "Updated " .. label(item),
        })
      end,
    })
  end,
}

M.actions.gl_approve = {
  desc = "Approve",
  icon = icons().check,
  type = "mr",
  priority = 45,
  enabled = is_open,
  action = function(item, ctx)
    call(item, ctx, { method = "POST", suffix = "/approve", success = "Approved " .. label(item) })
  end,
}

M.actions.gl_unapprove = {
  desc = "Revoke approval",
  icon = icons().cross,
  type = "mr",
  priority = 44,
  enabled = is_open,
  action = function(item, ctx)
    call(item, ctx, { method = "POST", suffix = "/unapprove", success = "Revoked approval on " .. label(item) })
  end,
}

---@param item snacks.gitlab.Item
---@param extra? table
local function merge_body(item, extra)
  return vim.tbl_extend("force", {
    squash = item.raw.squash_on_merge or item.raw.squash or nil,
    should_remove_source_branch = item.raw.force_remove_source_branch or item.raw.should_remove_source_branch or nil,
  }, extra or {})
end

M.actions.gl_merge = {
  desc = "Merge",
  icon = icons().mr.merged,
  type = "mr",
  priority = 40,
  enabled = function(item)
    return is_open(item) and not item.draft
  end,
  action = function(item, ctx)
    local how = item.raw.squash_on_merge and "Squash and merge" or "Merge"
    confirm(("%s %s into `%s`?"):format(how, label(item), item.raw.target_branch or "?"), function()
      call(item, ctx, { method = "PUT", suffix = "/merge", body = merge_body(item), success = "Merged " .. label(item) })
    end)
  end,
}

M.actions.gl_auto_merge = {
  desc = "Merge when pipeline succeeds",
  icon = icons().pipeline.running,
  type = "mr",
  priority = 39,
  enabled = function(item)
    return is_open(item) and not item.draft
  end,
  action = function(item, ctx)
    call(item, ctx, {
      method = "PUT",
      suffix = "/merge",
      -- `auto_merge` on GitLab 17+, `merge_when_pipeline_succeeds` on older versions
      body = merge_body(item, { auto_merge = true, merge_when_pipeline_succeeds = true }),
      success = "Set " .. label(item) .. " to merge when the pipeline succeeds",
    })
  end,
}

local draft_prefix = { "^[Dd]raft:%s*", "^%[[Dd]raft%]%s*", "^%([Dd]raft%)%s*", "^WIP:%s*", "^%[WIP%]%s*" }

M.actions.gl_ready = {
  desc = "Mark as ready",
  icon = icons().mr.open,
  type = "mr",
  priority = 35,
  enabled = function(item)
    return is_open(item) and item.draft
  end,
  action = function(item, ctx)
    local title = item.title
    for _, p in ipairs(draft_prefix) do
      title = title:gsub(p, "")
    end
    call(item, ctx, { method = "PUT", body = { title = title }, success = "Marked " .. label(item) .. " as ready" })
  end,
}

M.actions.gl_draft = {
  desc = "Mark as draft",
  icon = icons().mr.draft,
  type = "mr",
  priority = 35,
  enabled = function(item)
    return is_open(item) and not item.draft
  end,
  action = function(item, ctx)
    call(item, ctx, {
      method = "PUT",
      body = { title = "Draft: " .. item.title },
      success = "Marked " .. label(item) .. " as draft",
    })
  end,
}

M.actions.gl_labels = {
  desc = "Edit labels",
  icon = "\u{f02b} ",
  priority = 30,
  action = function(item, ctx)
    M.labels(item, ctx)
  end,
}

M.actions.gl_close = {
  desc = "Close",
  icon = icons().cross,
  priority = 20,
  enabled = is_open,
  action = function(item, ctx)
    confirm(("Close %s?"):format(label(item)), function()
      call(item, ctx, { method = "PUT", body = { state_event = "close" }, success = "Closed " .. label(item) })
    end)
  end,
}

M.actions.gl_reopen = {
  desc = "Reopen",
  icon = "\u{f01e} ",
  priority = 20,
  enabled = function(item)
    return item.state == "closed"
  end,
  action = function(item, ctx)
    call(item, ctx, { method = "PUT", body = { state_event = "reopen" }, success = "Reopened " .. label(item) })
  end,
}

--- Reply to a discussion thread
---@param item snacks.gitlab.Item
---@param thread snacks.gitlab.Thread
---@param on_done? fun()
function M.reply(item, thread, on_done)
  M.input({
    title = ("Reply to @%s's thread on %s"):format(thread.author, label(item)),
    on_submit = function(body)
      if not body:find("%S") then
        return
      end
      Api.request({
        host = item.host,
        method = "POST",
        endpoint = Item.endpoint(item, "/discussions/" .. thread.id .. "/notes"),
        body = { body = body },
      }, function(_, err)
        if err then
          return
        end
        vim.schedule(function()
          Snacks.notify.info(("Replied to @%s's thread"):format(thread.author), { title = "GitLab" })
          Buf.refresh(item)
          if on_done then
            on_done()
          end
        end)
      end)
    end,
  })
end

--- Resolve or unresolve a discussion thread (merge requests only)
---@param item snacks.gitlab.Item
---@param thread snacks.gitlab.Thread
---@param resolved boolean
---@param on_done? fun()
function M.resolve(item, thread, resolved, on_done)
  Api.request({
    host = item.host,
    method = "PUT",
    endpoint = Item.endpoint(item, "/discussions/" .. thread.id),
    body = { resolved = resolved },
  }, function(_, err)
    if err then
      return
    end
    vim.schedule(function()
      Snacks.notify.info(
        ("%s @%s's thread"):format(resolved and "Resolved" or "Unresolved", thread.author),
        { title = "GitLab" }
      )
      Buf.refresh(item)
      if on_done then
        on_done()
      end
    end)
  end)
end

M.actions.gl_reply = {
  needs_thread = true,
  desc = "Reply to thread",
  icon = "\u{f112} ",
  priority = 98,
  enabled = function(_, ctx)
    return ctx.thread ~= nil
  end,
  action = function(item, ctx)
    M.reply(item, assert(ctx.thread))
  end,
}

M.actions.gl_resolve = {
  needs_thread = true,
  desc = "Resolve thread",
  icon = icons().check,
  type = "mr",
  priority = 97,
  enabled = function(_, ctx)
    return ctx.thread ~= nil and ctx.thread.resolvable and not ctx.thread.resolved
  end,
  action = function(item, ctx)
    M.resolve(item, assert(ctx.thread), true)
  end,
}

M.actions.gl_unresolve = {
  needs_thread = true,
  desc = "Unresolve thread",
  icon = "\u{f01e} ",
  type = "mr",
  priority = 97,
  enabled = function(_, ctx)
    return ctx.thread ~= nil and ctx.thread.resolvable and ctx.thread.resolved
  end,
  action = function(item, ctx)
    M.resolve(item, assert(ctx.thread), false)
  end,
}

--- Toggle for a single buffer key
M.actions.gl_toggle_resolve = {
  needs_thread = true,
  desc = "Resolve / unresolve thread",
  type = "mr",
  hidden = true,
  enabled = function(_, ctx)
    return ctx.thread ~= nil and ctx.thread.resolvable
  end,
  action = function(item, ctx)
    local t = assert(ctx.thread)
    M.resolve(item, t, not t.resolved)
  end,
}

--- Actions that apply to the item, sorted for the menu
---@param item snacks.gitlab.Item
---@param ctx? snacks.gitlab.action.ctx
function M.available(item, ctx)
  ctx = ctx or {}
  local ret = {} ---@type (snacks.gitlab.Action|{name:string})[]
  for name, a in pairs(M.actions) do
    local ok = not a.hidden and (a.type == nil or a.type == item.type) and (a.enabled == nil or a.enabled(item, ctx))
    if ok then
      ret[#ret + 1] = setmetatable({ name = name }, { __index = a })
    end
  end
  table.sort(ret, function(a, b)
    if (a.priority or 0) ~= (b.priority or 0) then
      return (a.priority or 0) > (b.priority or 0)
    end
    return a.desc < b.desc
  end)
  return ret
end

--- Runs a named action
---@param name string
---@param item snacks.gitlab.Item
---@param ctx snacks.gitlab.action.ctx
function M.run(name, item, ctx)
  local a = M.actions[name]
  if not a then
    Snacks.notify.error("Unknown GitLab action: " .. name, { title = "GitLab" })
    return
  end
  if a.needs_thread and not ctx.thread then
    Snacks.notify.warn("Move the cursor onto a comment thread first", { title = "GitLab" })
    return
  end
  if (a.type and a.type ~= item.type) or (a.enabled and not a.enabled(item, ctx)) then
    Snacks.notify.warn(("`%s` is not available for %s"):format(a.desc, label(item)), { title = "GitLab" })
    return
  end
  a.action(item, ctx)
end

--- Actions menu for an item
---@param item snacks.gitlab.Item
---@param ctx snacks.gitlab.action.ctx
function M.menu(item, ctx)
  local actions = M.available(item, ctx)
  local items = {} ---@type snacks.picker.finder.Item[]
  for i, a in ipairs(actions) do
    items[#items + 1] = { idx = i, text = i .. ". " .. a.desc, action = a }
  end
  return Snacks.picker.pick({
    title = icons().logo .. label(item),
    items = items,
    layout = { preset = "select", layout = { max_width = 50, height = #items + 3 } },
    format = function(it)
      local w = #tostring(#items)
      return {
        { (it.action.icon or "  "), "Special" },
        { (" "):rep(w - #tostring(it.idx)) .. it.idx .. ". ", "SnacksPickerIdx" },
        { it.action.desc },
      }
    end,
    confirm = function(picker, it)
      picker:close()
      if not it then
        return
      end
      vim.schedule(function()
        if ctx.picker and not ctx.picker.closed then
          ctx.picker:focus()
        end
        it.action.action(item, ctx)
      end)
    end,
  })
end

--- Label editor: select labels to toggle them
---@param item snacks.gitlab.Item
---@param ctx snacks.gitlab.action.ctx
function M.labels(item, ctx)
  local current = {} ---@type table<string, boolean>
  for _, l in ipairs(item.labels) do
    current[l.name] = true
  end
  return Snacks.picker.pick({
    title = "\u{f02b} Labels for " .. label(item),
    layout = { preset = "select", layout = { max_width = 60 } },
    finder = function()
      ---@async
      return function(cb)
        local labels = Api.await({
          host = item.host,
          endpoint = ("projects/%s/labels"):format(Api.project(item.project)),
          query = { per_page = 100, include_ancestor_groups = true },
          paginate = true,
        }) or {}
        table.sort(labels, function(a, b)
          if (current[a.name] or false) ~= (current[b.name] or false) then
            return current[a.name] == true
          end
          return a.name:lower() < b.name:lower()
        end)
        for _, l in ipairs(labels) do
          cb({ text = l.name, label = l, added = current[l.name] == true })
        end
      end
    end,
    format = function(it, picker)
      local added = it.added
      if picker.list:is_selected(it) then
        added = not added
      end
      local ret = { { added and "\u{f0c52} " or "\u{f0131} ", "SnacksPickerDelim" }, { " " } }
      vim.list_extend(ret, Snacks.picker.highlight.badge(it.label.name, it.label.color or "#888888"))
      return ret
    end,
    confirm = function(picker)
      local add, remove = {}, {} ---@type string[], string[]
      for _, it in ipairs(picker:selected({ fallback = true })) do
        table.insert(it.added and remove or add, it.label.name)
      end
      picker:close()
      if #add + #remove == 0 then
        return
      end
      call(item, ctx, {
        method = "PUT",
        body = {
          add_labels = #add > 0 and table.concat(add, ",") or nil,
          remove_labels = #remove > 0 and table.concat(remove, ",") or nil,
        },
        success = "Updated labels on " .. label(item),
      })
    end,
  })
end

--- Actions for the open MR of the current branch (or the gitlab:// buffer)
function M.current()
  local item = Buf.get()
  if item then
    return M.menu(item, {})
  end
  local branch = vim.trim(vim.fn.system({ "git", "branch", "--show-current" }))
  if vim.v.shell_error ~= 0 or branch == "" then
    Snacks.notify.warn("Not on a git branch", { title = "GitLab" })
    return
  end
  Api.request({
    endpoint = "projects/:id/merge_requests",
    query = { source_branch = branch, state = "opened", with_labels_details = true },
  }, function(data)
    vim.schedule(function()
      local raw = data and data[1]
      if not raw then
        Snacks.notify.warn(("No open MR for branch `%s`"):format(branch), { title = "GitLab" })
        return
      end
      M.menu(Buf.remember(Item.new(raw, "mr")), {})
    end)
  end)
end

return M
