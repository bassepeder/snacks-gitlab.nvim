--- Snacks pickers for GitLab merge requests and issues
local Actions = require("snacks-gitlab.actions")
local Api = require("snacks-gitlab.api")
local Buf = require("snacks-gitlab.buf")
local Item = require("snacks-gitlab.item")
local Render = require("snacks-gitlab.render")

local M = {}

---@class snacks.gitlab.picker.Config: snacks.picker.Config
---@field project? string full project path ("group/repo"). Defaults to the repo in cwd
---@field host? string GitLab host. Defaults to the host of the repo in cwd
---@field state? "opened"|"closed"|"merged"|"all" (default "opened")
---@field scope? "all"|"created_by_me"|"assigned_to_me" (default "all")
---@field author? string author username
---@field assignee? string assignee username
---@field reviewer? string reviewer username (MRs only)
---@field labels? string comma separated labels
---@field milestone? string
---@field draft? boolean only drafts (true) or only non-drafts (false), MRs only
---@field target_branch? string MRs only
---@field limit? number

---@param kind snacks.gitlab.Type
---@param opts snacks.gitlab.picker.Config
---@param search string
local function list_query(kind, opts, search)
  local limit = opts.limit or require("snacks-gitlab").config().limit
  local q = {
    state = opts.state or "opened",
    scope = opts.scope,
    author_username = opts.author,
    assignee_username = opts.assignee,
    labels = opts.labels,
    milestone = opts.milestone,
    search = search ~= "" and search or nil,
    order_by = "updated_at",
    sort = "desc",
    per_page = math.min(limit, 100),
    with_labels_details = true,
  }
  if q.state == "all" then
    q.state = nil
  end
  if kind == "mr" then
    q.reviewer_username = opts.reviewer
    q.target_branch = opts.target_branch
    if opts.draft ~= nil then
      q.wip = opts.draft and "yes" or "no"
    end
  end
  return q
end

---@param kind snacks.gitlab.Type
---@return snacks.picker.finder
local function finder(kind)
  ---@param opts snacks.gitlab.picker.Config
  return function(opts, ctx)
    local search = ctx.filter.search or ""
    ---@async
    return function(cb)
      local data = Api.await({
        host = opts.host,
        cwd = ctx:git_root(),
        endpoint = ("projects/%s/%s"):format(Api.project(opts.project), kind == "mr" and "merge_requests" or "issues"),
        query = list_query(kind, opts, search),
      })
      for _, raw in ipairs(data or {}) do
        local item = Buf.remember(Item.new(raw, kind))
        item.preview = { text = table.concat(Render.lines(item), "\n"), ft = "markdown", loc = false }
        cb(item)
      end
    end
  end
end

---@param item snacks.gitlab.Item
---@type snacks.picker.format
function M.format(item, picker)
  local config = require("snacks-gitlab").config()
  local a = Snacks.picker.util.align
  local ret = {} ---@type snacks.picker.Highlight[]

  local icons = config.icons[item.type]
  local status = icons[item.status] and item.status or "other"
  local hl = "SnacksGitlab" .. (item.type == "mr" and "Mr" or "Issue") .. status:sub(1, 1):upper() .. status:sub(2)
  ret[#ret + 1] = { a(icons[status], 2), hl }
  ret[#ret + 1] = { " " }
  ret[#ret + 1] = { a(item.hash, 6), "SnacksPickerDimmed" }
  ret[#ret + 1] = { " " }

  local pipeline = item.raw.head_pipeline or item.raw.pipeline
  if item.type == "mr" and type(pipeline) == "table" and pipeline.status then
    local p = config.icons.pipeline[pipeline.status] and pipeline.status or "other"
    ret[#ret + 1] = { config.icons.pipeline[p], "SnacksGitlabPipeline" .. p:sub(1, 1):upper() .. p:sub(2) }
  end

  item.msg = item.title
  Snacks.picker.highlight.extend(ret, Snacks.picker.format.commit_message(item, picker))

  if item.author and not (item.raw.author or {}).bot then
    ret[#ret + 1] = { " " }
    ret[#ret + 1] = { "@" .. item.author, "SnacksPickerGitAuthor" }
  end
  for _, l in ipairs(item.labels) do
    ret[#ret + 1] = { " " }
    vim.list_extend(ret, Snacks.picker.highlight.badge(l.name, l.color or "#888888"))
  end
  if item.updated then
    ret[#ret + 1] = { " " }
    ret[#ret + 1] = { Snacks.picker.util.reltime(item.updated), "SnacksPickerGitDate" }
  end
  return ret
end

--- Wraps a named GitLab action as a Snacks picker action
---@param name string
local function picker_action(name)
  local a = Actions.actions[name]
  return {
    desc = a and a.desc or name,
    action = function(picker, item)
      if not item then
        return
      end
      Actions.run(name, item, { picker = picker, items = picker:selected({ fallback = true }) })
    end,
  }
end

---@param kind snacks.gitlab.Type
---@param opts? snacks.gitlab.picker.Config
function M.open(kind, opts)
  local config = require("snacks-gitlab").config()
  local picker_actions = {}
  for name in pairs(Actions.actions) do
    picker_actions[name] = picker_action(name)
  end
  -- <cr> opens the actions menu, but forwards split/vsplit/tab to a plain jump
  picker_actions.confirm = function(picker, item, action)
    if not item then
      return
    end
    if action and action.cmd then
      return Snacks.picker.actions.jump(picker, item, action)
    end
    Actions.menu(item, { picker = picker, items = picker:selected({ fallback = true }) })
  end

  local state = opts and opts.state or "opened"
  ---@type snacks.gitlab.picker.Config
  local defaults = {
    title = ("%s%s (%s)"):format(config.icons.logo, kind == "mr" and "Merge Requests" or "Issues", state),
    finder = finder(kind),
    format = M.format,
    preview = "preview",
    live = true,
    supports_live = true,
    sort = { fields = { "score:desc", "idx" } },
    actions = picker_actions,
    win = {
      input = {
        keys = {
          ["<a-b>"] = { "gl_browse", mode = { "n", "i" } },
          ["<c-y>"] = { "gl_yank", mode = { "n", "i" } },
          ["<a-o>"] = { "gl_checkout", mode = { "n", "i" } },
          ["<a-c>"] = { "gl_comment", mode = { "n", "i" } },
          ["<a-d>"] = { "gl_diff", mode = { "n", "i" } },
        },
      },
      list = {
        keys = {
          ["y"] = { "gl_yank", mode = { "n", "x" } },
        },
      },
    },
  }
  return Snacks.picker.pick(vim.tbl_deep_extend("force", defaults, opts or {}))
end

return M
