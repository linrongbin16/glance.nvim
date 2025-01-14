local Renderer = require('glance.renderer')
local Winbar = require('glance.winbar')
local lsp = require('glance.lsp')
local Range = require('glance.range')
local folds = require('glance.folds')
local config = require('glance.config')
local utils = require('glance.utils')
local List = {}
List.__index = List

local winhl = {
  'Normal:GlanceListNormal',
  'CursorLine:GlanceListCursorLine',
  'EndOfBuffer:GlanceListEndOfBuffer',
}

local win_opts = {
  winfixwidth = true,
  winfixheight = true,
  cursorline = true,
  wrap = false,
  signcolumn = 'no',
  foldenable = false,
  winhighlight = table.concat(winhl, ','),
}

local buf_opts = {
  bufhidden = 'wipe',
  buftype = 'nofile',
  swapfile = false,
  buflisted = false,
  filetype = 'Glance',
}

function List.create(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  local winnr = vim.api.nvim_open_win(bufnr, true, opts.win_opts)

  local list = List:new(bufnr, winnr)
  utils.win_set_options(winnr, win_opts)
  utils.buf_set_options(bufnr, buf_opts)
  list:setup(opts)
  list:set_keymaps()

  return list
end

function List:new(bufnr, winnr)
  local scope = {
    bufnr = bufnr,
    winnr = winnr,
    items = {},
    groups = {},
  }

  setmetatable(scope, self)
  return scope
end

function List:set_keymaps()
  local mappings = config.options.mappings

  local keymap_opts = {
    buffer = self.bufnr,
    noremap = true,
    nowait = true,
    silent = true,
  }

  for key, action in pairs(mappings.list) do
    vim.keymap.set('n', key, action, keymap_opts)
  end
end

function List:is_valid()
  return self.winnr and vim.api.nvim_win_is_valid(self.winnr)
end

local function find_location_position(items, location)
  return utils.tbl_find(items, function(item)
    return vim.deep_equal(item, location)
  end)
end

local function find_starting_location(locations)
  return utils.tbl_find(locations, function(location)
    return location.is_starting
  end)
end

local function find_starting_group_and_location(groups, position_params)
  local fallback = nil
  for _, group in pairs(groups) do
    local starting_location = find_starting_location(group.items)

    if starting_location then
      return group, starting_location
    end

    if not fallback and position_params.textDocument.uri == group.uri then
      fallback = { group = group, location = group.items[1] }
    end
  end

  if fallback then
    return fallback.group, fallback.location
  end

  -- if nothing was found return the first group and location
  local _, group = next(groups)
  return group, group.items[1]
end

local function is_starting_location(
  position_params,
  location_uri,
  location_range
)
  if location_uri ~= position_params.textDocument.uri then
    return false
  end

  local range = Range:new(
    location_range.start.line,
    location_range.start.character,
    location_range.finish.line,
    location_range.finish.character
  )

  return range:contains_position({
    line = position_params.position.line,
    col = position_params.position.character,
  })
end

local function get_preview_line(range, offset, text)
  local word = utils.get_word_until_position(range.start_col - offset, text)

  if range.end_line > range.start_line then
    range.end_col = string.len(text) + 1
  end

  local before = utils
    .get_value_in_range(word.start_col, range.start_col, text)
    :gsub('^%s+', '')
  local inside = utils.get_value_in_range(range.start_col, range.end_col, text)
  local after = utils
    .get_value_in_range(range.end_col, string.len(text) + 1, text)
    :gsub('%s+$', '')

  return {
    value = {
      before = before,
      inside = inside,
      after = after,
    },
  }
end

local function process_locations(locations, position_params, offset_encoding)
  return vim.tbl_map(function(location)
    local is_unreachable = false
    local preview_line, line
    local uri = location.uri or location.targetUri
    local bufnr = vim.uri_to_bufnr(uri)
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local range = location.range or location.targetSelectionRange
    local start = range['start']
    local finish = range['end']
    local start_col = start.character
    local end_col = finish.character

    local row = start.line

    if not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end
    line = (vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false) or { '' })[1]

    if not line then
      line = ('%s:%d:%d'):format(
        vim.fn.fnamemodify(filename, ':t'),
        start_col + 1,
        end_col + 1
      )
      is_unreachable = true
    else
      start_col =
        utils.get_line_byte_from_position(line, start, offset_encoding)
      end_col = utils.get_line_byte_from_position(line, finish, offset_encoding)

      preview_line = get_preview_line({
        start_line = row,
        start_col = start_col,
        end_col = end_col,
        end_line = finish.line,
      }, 8, line)
    end

    return {
      bufnr = bufnr,
      filename = filename,
      uri = uri,
      preview_line = preview_line,
      start_col = start_col,
      end_col = end_col,
      start_line = start.line,
      end_line = finish.line,
      is_starting = is_starting_location(
        position_params,
        uri,
        { start = start, finish = finish }
      ),
      full_text = line or '',
      is_unreachable = is_unreachable,
    }
  end, locations or {})
end

local function get_lsp_method_label(method_name)
  return utils.capitalize(lsp.methods[method_name].label)
end

function List:setup(opts)
  local processed_locations =
    process_locations(opts.results, opts.position_params, opts.offset_encoding)
  self.groups = utils.list_to_tree(processed_locations)
  local group, location =
    find_starting_group_and_location(self.groups, opts.position_params)
  folds.open(group.filename)
  self:update(self.groups)
  local _, location_line = find_location_position(self.items, location)

  if config.options.winbar.enable then
    local winbar = Winbar:new(self.winnr)
    winbar:append('title', 'WinBarTitle')
    winbar:render({
      title = string.format(
        '%s (%d)',
        get_lsp_method_label(opts.method),
        #opts.results
      ),
    })
  end

  vim.api.nvim_win_set_cursor(self.winnr, { location_line, 1 })
end

function List:update(groups)
  utils.buf_set_options(self.bufnr, { modifiable = true, readonly = false })
  self:render(groups)
  utils.buf_set_options(self.bufnr, { modifiable = false, readonly = true })
end

function List:close()
  if vim.api.nvim_win_is_valid(self.winnr) then
    vim.api.nvim_win_close(self.winnr, {})
  end

  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_delete(self.bufnr, {})
  end

  folds.reset()
end

function List:destroy()
  self.winnr = nil
  self.bufnr = nil
  self.items = nil
  self.groups = nil
end

function List:render(groups)
  local renderer = Renderer:new(self.bufnr)
  local icons = config.options.folds

  if vim.tbl_count(groups) > 1 then
    for filename, group in pairs(groups) do
      self.items[renderer.line_nr + 1] = {
        filename = filename,
        uri = group.uri,
        is_group = true,
        count = #group.items,
      }

      local is_folded = folds.is_folded(filename)
      local fold_icon = is_folded and icons.fold_closed or icons.fold_open

      renderer:append(string.format(' %s ', fold_icon), 'FoldIcon')
      renderer:append(vim.fn.fnamemodify(filename, ':t'), 'ListFilename', ' ')
      renderer:append(
        vim.fn.fnamemodify(filename, ':p:.:h'),
        'ListFilepath',
        ' '
      )
      renderer:append(string.format(' %d ', #group.items), 'ListCount', ' ')
      renderer:nl()

      if not is_folded then
        self:render_locations(group.items, renderer)
      end
    end
  else
    local _, group = next(groups)
    self:render_locations(group.items, renderer)
  end

  renderer:render()
  renderer:highlight()
end

function List:render_locations(locations, renderer)
  for _, location in ipairs(locations) do
    self.items[renderer.line_nr + 1] = location

    local indent = '    '
    if config.options.indent_lines.enable then
      indent = string.format(' %s  ', config.options.indent_lines.icon)
    elseif not config.options.folds.enable then
      indent = ' '
    end

    renderer:append(indent, 'Indent')

    if location.preview_line then
      local preview_line = location.preview_line.value
      renderer:append(preview_line.before)
      renderer:append(preview_line.inside, 'ListMatch')
      renderer:append(preview_line.after)
    else
      renderer:append(location.full_text)
    end

    renderer:nl()
  end
end

function List:get_cursor()
  return vim.api.nvim_win_get_cursor(self.winnr)
end

function List:get_line()
  return self:get_cursor()[1]
end

function List:get_col()
  return self:get_cursor()[2]
end

function List:get_current_item()
  local line = self:get_line() or 1
  local item = self.items[line]
  return item
end

---@param opts { start: integer, backwards?: boolean, cycle?: boolean }
function List:walk(opts)
  local idx = opts.start
  return function()
    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    idx = idx + (opts.backwards and -1 or 1)
    if opts.cycle then
      idx = ((idx - 1) % line_count) + 1
    end
    local item = self.items[idx]
    if not item or idx > line_count then
      return nil
    end
    return idx, item
  end
end

function List:next(opts)
  opts = opts or {}
  for i, item in
    self:walk({
      start = self:get_line() + (opts.offset or 0),
      cycle = opts.cycle,
    })
  do
    if
      opts.skip_groups
      and item.is_group
      and folds.is_folded(item.filename)
    then
      self:toggle_fold(item)
      return self:next({
        offset = i - self:get_line(), -- offset by how far we've already iterated prior to unfolding
        cycle = opts.cycle,
        skip_groups = true,
      })
    end
    if not (opts.skip_groups and item.is_group) then
      vim.api.nvim_win_set_cursor(self.winnr, { i, self:get_col() })
      return item
    end
  end
  return nil
end

function List:previous(opts)
  opts = opts or {}
  for i, item in
    self:walk({
      start = self:get_line() + (opts.offset or 0),
      cycle = opts.cycle,
      backwards = true,
    })
  do
    if
      opts.skip_groups
      and item.is_group
      and folds.is_folded(item.filename)
    then
      local is_last_line = i == vim.api.nvim_buf_line_count(self.bufnr)
      self:toggle_fold(item)
      return self:previous({
        offset = is_last_line and 0 or item.count, -- offset by how many new items were added after unfolding
        cycle = opts.cycle,
        skip_groups = true,
      })
    end
    if not (opts.skip_groups and item.is_group) then
      vim.api.nvim_win_set_cursor(self.winnr, { i, self:get_col() })
      return item
    end
  end
  return nil
end

function List:get_active_group(opts)
  local current_location = opts.location or self:get_current_item()
  return self.groups[current_location.filename]
end

function List:toggle_fold(item)
  folds.toggle(item.filename)
  self:update(self.groups)
end

return List
