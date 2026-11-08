if vim.g.loaded_snacks_gitlab then
  return
end
vim.g.loaded_snacks_gitlab = true

-- gitlab:// buffers (cheap: only registers autocmds)
require("snacks-gitlab.buf").setup()

local subcommands = {
  mr = function(opts)
    require("snacks-gitlab").mr(opts)
  end,
  issue = function(opts)
    require("snacks-gitlab").issue(opts)
  end,
  current = function()
    require("snacks-gitlab").current()
  end,
}

--- :GitLab mr state=all author=me
vim.api.nvim_create_user_command("GitLab", function(cmd)
  local sub = cmd.fargs[1] or "mr"
  local fn = subcommands[sub]
  if not fn then
    Snacks.notify.error("Unknown subcommand: " .. sub, { title = "GitLab" })
    return
  end
  local opts = {}
  for i = 2, #cmd.fargs do
    local k, v = cmd.fargs[i]:match("^([%w_]+)=(.*)$")
    if k then
      opts[k] = v == "true" and true or v == "false" and false or v
    end
  end
  fn(opts)
end, {
  nargs = "*",
  desc = "GitLab pickers",
  complete = function(arg, line)
    if #vim.split(line, "%s+") <= 2 then
      return vim.tbl_filter(function(s)
        return s:find("^" .. vim.pesc(arg))
      end, vim.tbl_keys(subcommands))
    end
    return { "state=", "scope=", "author=", "assignee=", "reviewer=", "labels=", "project=", "draft=" }
  end,
})
