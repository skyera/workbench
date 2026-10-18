-- Shell configuration: use bash when running inside Git Bash on Windows
if vim.fn.has("win32") == 1 and vim.env.MSYSTEM then
    vim.opt.shell = "bash"
    vim.opt.shellcmdflag = "-c"
    vim.opt.shellquote = ""
    vim.opt.shellxquote = ""
end

-- Disable legacy remote providers for fast startup
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_node_provider = 0

-- General settings (translated from myvimrc)
vim.opt.backspace = { "indent", "eol", "start" }
vim.opt.history = 10000
vim.opt.ruler = true
vim.opt.showcmd = true
vim.opt.incsearch = true
vim.opt.hlsearch = true
vim.opt.mouse = "a"
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.number = true
vim.opt.autoindent = true
vim.opt.copyindent = true
vim.opt.backup = false
vim.opt.swapfile = false
vim.opt.showmode = true
vim.opt.completeopt = { "menu" }
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.cursorline = true
vim.opt.shiftround = true
vim.opt.encoding = "utf-8"
vim.opt.colorcolumn = "80"
vim.opt.termguicolors = true
vim.opt.laststatus = 2
vim.opt.wrapscan = true
vim.opt.cindent = true
vim.opt.cinoptions = "g-1"
vim.opt.listchars = { tab = "▸ ", trail = "·", extends = "❯", precedes = "❮", nbsp = "␣" }
vim.opt.directory:prepend(vim.fn.expand("$HOME") .. "/.vim/tmp//")

-- Clipboard logic
if vim.fn.has("clipboard") == 1 then
  if vim.fn.has("unnamedplus") == 1 then
    vim.opt.clipboard = "unnamedplus"
  else
    vim.opt.clipboard = "unnamed"
  end
end

-- Font settings
if vim.fn.has("win32") == 1 then
  vim.opt.guifont = "Hack Nerd Font Mono:h11"
elseif vim.fn.has("linux") == 1 then
  vim.opt.guifont = "Hack Nerd Font:h10"
elseif vim.fn.has("mac") == 1 then
  vim.opt.guifont = "Hack Nerd Font:h11"
end

-- Plugin Globals
vim.g.lf_map_keys = 0
vim.g.ranger_map_keys = 0
vim.g.winManagerWindowLayout = 'FileExplorer|TagList'
vim.g.Tlist_Show_One_File = 1
vim.g.LookupFile_MinPatLength = 3
vim.g.LookupFile_PreserveLastPattern = 0
vim.g.LookupFile_PreservePatternHistory = 1
vim.g.LookupFile_AlwaysAcceptFirst = 1
vim.g.LookupFile_AllowNewFiles = 0
vim.g.LookupFile_smartcase = 1
vim.g.LookupFile_EscCancelsPopup = 1
vim.g.LookupFile_ignorecase = 1
vim.g.LookupFile_EnableRemapCmd = 0
vim.g.LookupFile_TagExpr = '"filenametags"'

-- Use Ripgrep for native :grep if available
if vim.fn.executable("rg") == 1 then
  vim.opt.grepprg = "rg --vimgrep --no-heading --smart-case"
  vim.opt.grepformat = "%f:%l:%c:%m"
end

-- Tagbar TypeScript
vim.g.tagbar_type_typescript = {
  ctagstype = 'typescript',
  kinds = { 'c:classes', 'n:modules', 'f:functions', 'v:variables', 'v:varlambdas', 'm:members', 'i:interfaces', 'e:enums' }
}

-- FZF Configuration (fzf.vim)
vim.g.fzf_command_prefix = "Fzf"
vim.g.fzf_layout = { window = { width = 0.9, height = 0.9 } }
vim.g.fzf_preview_window = { "down:50%", "ctrl-/" }
vim.env.FZF_DEFAULT_OPTS = (vim.env.FZF_DEFAULT_OPTS or "") .. ' --layout=reverse --bind "ctrl-q:select-all+accept,ctrl-a:select-all,ctrl-d:deselect-all"'

-- Custom Frg and interactive FzfRG live ripgrep command
vim.cmd([[
  function! RipgrepFzf(query, fullscreen)
    let command_fmt = 'rg --column --line-number --no-heading --color=always --smart-case --hidden --glob "!.git" -- %s || true'
    let initial_command = printf(command_fmt, shellescape(a:query))
    let reload_command = printf(command_fmt, '{q}')
    let spec = {'options': ['--phony', '--query', a:query, '--bind', 'change:reload:'.reload_command]}
    call fzf#vim#grep(initial_command, 1, fzf#vim#with_preview(spec, 'down:50%'), a:fullscreen)
  endfunction

  command! -nargs=* -bang FzfRG call RipgrepFzf(<q-args>, <bang>0)
  command! -nargs=* -bang FRG call RipgrepFzf(<q-args>, <bang>0)
  command! -bang -nargs=* Frg call fzf#vim#grep("rg --column --line-number --no-heading --color=always --smart-case ".<q-args>, 1, fzf#vim#with_preview({}, 'down:50%'), <bang>0)
]])

-- Theme settings
pcall(vim.cmd, "colorscheme catppuccin")
vim.opt.background = "dark"

-- Auto-restore cursor position
vim.api.nvim_create_autocmd("BufReadPost", {
  callback = function()
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    local lcount = vim.api.nvim_buf_line_count(0)
    if mark[1] > 0 and mark[1] <= lcount then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Prefer built-in syntax rules after filetype plugins start their highlighters.
vim.cmd("syntax enable")
local builtin_syntax_group = vim.api.nvim_create_augroup("builtin_syntax", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
    group = builtin_syntax_group,
    pattern = "*",
    callback = function(event)
        vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(event.buf) then
                return
            end

            vim.treesitter.stop(event.buf)
            vim.bo[event.buf].syntax = vim.bo[event.buf].filetype
        end)
    end,
})

-- FileType specific settings
-- Filename detection also handles new or empty memory-tool logs.
vim.filetype.add({
  -- Built-in generic log syntax; specific patterns below take priority.
  extension = {
    log = function(_, bufnr)
      local filetype = vim.bo[bufnr].filetype
      return filetype ~= "" and filetype or "log"
    end,
  },
  pattern = {
    ["valgrind_.*%.log"] = "valgrind",
    ["compute%-sanitizer.*%.log"] = "computesanitizer",
    ["compute_sanitizer.*%.log"] = "computesanitizer",
    ["cuda%-memcheck.*%.log"] = "computesanitizer",
  },
})

-- Detect renamed logs once on opening; preserve source-code filetypes.
local valgrind_signature = vim.regex(
  [[^==\d\+==\s\+\%(Memcheck,\|Using [Vv]algrind\|Invalid \%(read\|write\|free\)\>\|HEAP SUMMARY:\|LEAK SUMMARY:\|ERROR SUMMARY:\)]]
)
local compute_sanitizer_signature = vim.regex(
  [[^=\{8,}\s\+\%(COMPUTE-SANITIZER\|Invalid __\|Uninitialized __\|Misaligned __\|Malloc/Free error\|Leaked \d\+ bytes\|Program hit .*\%(cudaError\|CUDA_ERROR\|CUDA API\)\|Barrier error detected\|Warpgroup MMA sequence error detected\|\%(Error\|ERROR\|WARNING\|Warning\|INFO\): \%(Race reported\|Potential \%(WAW\|WAR\|RAW\) hazard\)\|\%(ERROR\|RACECHECK\) SUMMARY:\)]]
)
local memory_tool_group = vim.api.nvim_create_augroup("valgrind_logs", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", {
  group = memory_tool_group,
  callback = function(event)
    local filetype = vim.bo[event.buf].filetype
    if filetype ~= "" and filetype ~= "log" then
      return
    end
    local line_count = math.min(50, vim.api.nvim_buf_line_count(event.buf))
    for _, line in ipairs(vim.api.nvim_buf_get_lines(event.buf, 0, line_count, false)) do
      if compute_sanitizer_signature:match_str(line) then
        vim.bo[event.buf].filetype = "computesanitizer"
        return
      end
      if valgrind_signature:match_str(line) then
        vim.bo[event.buf].filetype = "valgrind"
        return
      end
    end
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "javascript", "html", "sh", "bash" },
  callback = function()
    vim.opt_local.shiftwidth = 2
    vim.opt_local.tabstop = 2
    vim.opt_local.softtabstop = 2
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function()
    vim.opt_local.foldmethod = "indent"
  end,
})

-- Vimwiki Configuration
vim.g.vimwiki_list = {
  {
    path = "~/vimwiki/",
    syntax = "markdown",
    ext = ".md",
  },
}
vim.g.vimwiki_hl_headers = 1
vim.g.vimwiki_hl_cb_checked = 1

-- Codeium: Start disabled by default for dynamic toggling
vim.g.codeium_enabled = 0

-- Performance & LSP Settings
vim.opt.updatetime = 200



vim.diagnostic.config({
  virtual_text = false,
  signs = false,
  underline = false,
  update_in_insert = false,
  severity_sort = true,
})

-- Show diagnostic float automatically when cursor rests on a line
vim.api.nvim_create_autocmd("CursorHold", {
  callback = function()
    vim.diagnostic.open_float(nil, { focus = false })
  end,
})

