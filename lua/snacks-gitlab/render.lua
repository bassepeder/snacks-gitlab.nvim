--- Renders merge requests / issues as markdown.
local Item = require("snacks-gitlab.item")

local M = {}

---@class snacks.gitlab.Details
---@field discussions? table[] GitLab discussions (oldest first)
---@field approvals? {approved_by?: {user:{username:string}}[], approvals_required?: number, approvals_left?: number}

local function reltime(t)
  return t and Snacks.picker.util.reltime(t) or ""
end

---@param s? string
local function lines_of(s)
  return vim.split((s or ""):gsub("\r\n", "\n"), "\n", { plain = true })
end

--- Comment bodies: markdown headings become bold text, so they don't
--- look like the start of a new comment
---@param s? string
local function note_lines(s)
  local ret = lines_of(s)
  local fence = false
  for i, l in ipairs(ret) do
    if l:match("^%s*```") then
      fence = not fence
    elseif not fence then
      local text = l:match("^#+%s+(.-)%s*#*$")
      if text then
        ret[i] = "**" .. text .. "**"
      end
    end
  end
  return ret
end

---@class snacks.gitlab.Thread
---@field id string discussion id
---@field resolvable boolean
---@field resolved boolean
---@field author string username of the first note
---@field file? string set for diff threads
---@field line? number

--- Thread info for a discussion
---@param d table
---@return snacks.gitlab.Thread
function M.thread(d)
  local first = d.notes[1]
  local resolvable, resolved = false, true
  for _, n in ipairs(d.notes) do
    if n.resolvable then
      resolvable = true
      resolved = resolved and n.resolved == true
    end
  end
  local pos = type(first.position) == "table" and first.position or nil
  return {
    id = d.id,
    resolvable = resolvable,
    resolved = resolvable and resolved,
    author = first.author and first.author.username or "?",
    file = pos and (pos.new_line and pos.new_path or pos.old_path) or nil,
    line = pos and (pos.new_line or pos.old_line) or nil,
  }
end

--- Renders the item. Also returns which lines belong to which thread
--- (`threads[lnum]`), so actions can target the thread under the cursor.
---@param item snacks.gitlab.Item
---@param details? snacks.gitlab.Details
---@return string[] lines, table<number, snacks.gitlab.Thread> threads
function M.lines(item, details)
  local config = require("snacks-gitlab").config()
  local raw = item.raw
  local ret = {} ---@type string[]
  local function add(...)
    for _, l in ipairs({ ... }) do
      ret[#ret + 1] = l
    end
  end

  add("# " .. item.title, "")

  local state = item.status
  local meta = {
    ("**%s**"):format(raw.references and raw.references.full or (item.project .. item.hash)),
    "`" .. state .. "`",
  }
  if item.author then
    meta[#meta + 1] = ("by @%s"):format(item.author)
  end
  if item.created then
    meta[#meta + 1] = "opened " .. reltime(item.created)
  end
  if raw.merged_at then
    meta[#meta + 1] = "merged " .. reltime(Item.ts(raw.merged_at))
  elseif raw.closed_at then
    meta[#meta + 1] = "closed " .. reltime(Item.ts(raw.closed_at))
  end
  add(table.concat(meta, " · "))

  if item.type == "mr" then
    add(("%s`%s` → `%s`"):format(config.icons.branch, raw.source_branch or "?", raw.target_branch or "?"))
    local pipeline = raw.head_pipeline or raw.pipeline
    if type(pipeline) == "table" and pipeline.status then
      local icon = config.icons.pipeline[pipeline.status] or config.icons.pipeline.other
      add(("%sPipeline [#%s](%s): **%s**"):format(icon, pipeline.id, pipeline.web_url or "", pipeline.status))
    end
    if raw.detailed_merge_status and item.state == "opened" then
      add(("Merge status: `%s`%s"):format(raw.detailed_merge_status, raw.has_conflicts and " · **conflicts**" or ""))
    end
    local appr = details and details.approvals
    if appr then
      local by = vim.tbl_map(function(a)
        return "@" .. a.user.username
      end, appr.approved_by or {})
      local s = #by > 0 and (config.icons.check .. "Approved by " .. table.concat(by, ", ")) or "Not approved yet"
      if (appr.approvals_left or 0) > 0 then
        s = s .. (" · %d more required"):format(appr.approvals_left)
      end
      add(s)
    end
    local reviewers = vim.tbl_map(function(u)
      return "@" .. u.username
    end, raw.reviewers or {})
    if #reviewers > 0 then
      add("Reviewers: " .. table.concat(reviewers, ", "))
    end
  end

  local assignees = vim.tbl_map(function(u)
    return "@" .. u.username
  end, raw.assignees or {})
  if #assignees > 0 then
    add("Assignees: " .. table.concat(assignees, ", "))
  end
  if #item.labels > 0 then
    add("Labels: " .. table.concat(
      vim.tbl_map(function(l)
        return "`" .. l.name .. "`"
      end, item.labels),
      " "
    ))
  end
  if raw.milestone and raw.milestone.title then
    add("Milestone: " .. raw.milestone.title)
  end

  add("", "---", "")
  if vim.trim(item.body) == "" then
    add("_No description provided._")
  else
    vim.list_extend(ret, lines_of(item.body))
  end

  local threads = {} ---@type table<number, snacks.gitlab.Thread>
  local discussions = details and details.discussions
  if discussions then
    local count = 0
    for _, d in ipairs(discussions) do
      count = count + #(d.notes or {})
    end
    add("", "---", "", ("## Activity (%d)"):format(count), "")
    for _, d in ipairs(discussions) do
      if d.notes and #d.notes > 0 then
        local first = #ret + 1
        local thread = M.thread(d)
        vim.list_extend(ret, M.discussion(d, thread))
        if not d.notes[1].system then
          for l = first, #ret do
            threads[l] = thread
          end
        end
      end
    end
  end
  return ret, threads
end

--- A discussion: the first note with its replies underneath
---@param d table
---@param thread snacks.gitlab.Thread
function M.discussion(d, thread)
  local ret = {} ---@type string[]
  for i, note in ipairs(d.notes) do
    local user = note.author and note.author.username or "?"
    local when = reltime(Item.ts(note.created_at))
    if note.system then
      ret[#ret + 1] = ("- _@%s %s · %s_"):format(user, ((note.body or ""):gsub("\n.*", "")), when)
    elseif i == 1 then
      local header = ("### @%s · %s"):format(user, when)
      if thread.file then
        header = header .. (" · on `%s:%s`"):format(thread.file, thread.line or "?")
      end
      if thread.resolvable then
        header = header .. (thread.resolved and " · resolved" or " · **unresolved**")
      end
      ret[#ret + 1] = header
      ret[#ret + 1] = ""
      vim.list_extend(ret, note_lines(note.body))
      ret[#ret + 1] = ""
    else
      ret[#ret + 1] = ("> **↳ @%s** · %s"):format(user, when)
      ret[#ret + 1] = ">"
      for _, l in ipairs(note_lines(note.body)) do
        ret[#ret + 1] = l == "" and ">" or ("> " .. l)
      end
      ret[#ret + 1] = ""
    end
  end
  return ret
end

return M
