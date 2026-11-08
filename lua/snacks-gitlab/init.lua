---@class snacks.gitlab
local M = {}

---@class snacks.gitlab.Keymap
---@field [1] string lhs
---@field [2] string action name
---@field desc? string
---@field mode? string|string[]

---@class snacks.gitlab.Config
local defaults = {
  limit = 50, -- items fetched per picker
  --- Keymaps in gitlab:// buffers. Set an entry to `false` to disable it.
  ---@type table<string, snacks.gitlab.Keymap|false>
  -- stylua: ignore
  keys = {
    select  = { "<cr>", "gl_actions", desc = "Select Action" },
    diff    = { "d",    "gl_diff",    desc = "View diff" },
    comment = { "a",    "gl_comment", desc = "Add Comment" },
    reply   = { "r",    "gl_reply",   desc = "Reply to thread" },
    resolve = { "x",    "gl_toggle_resolve", desc = "Resolve / unresolve thread" },
    close   = { "c",    "gl_close",   desc = "Close" },
    reopen  = { "o",    "gl_reopen",  desc = "Reopen" },
    browse  = { "gx",   "gl_browse",  desc = "Open in browser" },
    refresh = { "R",    "gl_refresh", desc = "Refresh" },
  },
  ---@type vim.wo|{}
  wo = {
    breakindent = true,
    wrap = true,
    linebreak = true,
    number = false,
    relativenumber = false,
    conceallevel = 2,
    concealcursor = "n",
    list = false,
  },
  scratch = { height = 15 },
  -- stylua: ignore
  -- Nerd Font codepoints written as escapes so they survive any editor/encoding
  icons = {
    logo      = "\u{f296} ",
    user      = "\u{f007} ",
    check     = "\u{f00c} ",
    cross     = "\u{f00d} ",
    branch    = "\u{e725} ",
    mr = {
      open   = "\u{f407} ",
      closed = "\u{f4dc} ",
      merged = "\u{f419} ",
      draft  = "\u{f4dd} ",
      other  = "\u{f407} ",
    },
    issue = {
      open   = "\u{f41b} ",
      closed = "\u{f41d} ",
      other  = "\u{f41b} ",
    },
    pipeline = {
      success  = "\u{f058} ",
      failed   = "\u{f057} ",
      running  = "\u{f192} ",
      pending  = "\u{f017} ",
      canceled = "\u{f05e} ",
      skipped  = "\u{f04e} ",
      manual   = "\u{f013} ",
      other    = "\u{f111} ",
    },
  },
}

M._config = nil ---@type snacks.gitlab.Config?

local set_hl ---@type fun()

function M.config()
  if not M._config then
    M._config = vim.deepcopy(defaults)
    set_hl()
  end
  return M._config
end

function set_hl()
  local hl = {
    Green = { fg = "#2da160" },
    Purple = { fg = "#7b58cf" },
    Gray = { fg = "#89888d" },
    Red = { fg = "#dd2b0e" },
    Blue = { fg = "#1f75cb" },
    MrOpen = "SnacksGitlabGreen",
    MrClosed = "SnacksGitlabRed",
    MrMerged = "SnacksGitlabBlue",
    MrDraft = "SnacksGitlabGray",
    MrOther = "SnacksGitlabGray",
    IssueOpen = "SnacksGitlabGreen",
    IssueClosed = "SnacksGitlabBlue",
    IssueOther = "SnacksGitlabGray",
    PipelineSuccess = "SnacksGitlabGreen",
    PipelineFailed = "SnacksGitlabRed",
    PipelineRunning = "SnacksGitlabBlue",
    PipelinePending = "DiagnosticWarn",
    PipelineCanceled = "SnacksGitlabGray",
    PipelineSkipped = "SnacksGitlabGray",
    PipelineManual = "SnacksGitlabGray",
    PipelineOther = "SnacksGitlabGray",
  }
  for name, v in pairs(hl) do
    local def = type(v) == "string" and { link = v } or v
    def.default = true
    vim.api.nvim_set_hl(0, "SnacksGitlab" .. name, def)
  end
end

--- Optional: only needed to change the defaults
---@param opts? snacks.gitlab.Config
function M.setup(opts)
  M._config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  set_hl()
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("snacks.gitlab.hl", { clear = true }),
  callback = function()
    set_hl()
  end,
})

--- Merge request picker
---@param opts? snacks.gitlab.picker.Config
function M.mr(opts)
  return require("snacks-gitlab.picker").open("mr", opts)
end

--- Issue picker
---@param opts? snacks.gitlab.picker.Config
function M.issue(opts)
  return require("snacks-gitlab.picker").open("issue", opts)
end

--- Actions for the MR of the current branch
function M.current()
  return require("snacks-gitlab.actions").current()
end

return M
