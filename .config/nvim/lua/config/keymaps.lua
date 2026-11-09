-- Keymaps (translated from myvimrc)
vim.g.mapleader = "\\" -- Set backslash as leader

-- General mappings
vim.keymap.set("n", "<leader>ll", ":LUBufs<cr>", { silent = true })
vim.keymap.set("n", "<F6>", ":cn<cr>")
vim.keymap.set("n", "<F7>", ":cp<cr>")
vim.keymap.set("n", "<F8>", ":bn<cr>")
vim.keymap.set("n", "<F9>", ":bp<cr>")
vim.keymap.set("n", "<F10>", ":tn<cr>")
vim.keymap.set("n", "<C-F10>", ":tp<cr>")
vim.keymap.set("n", "<F4>", ':execute "vimgrep /" . expand("<cword>") . "/j **" <Bar> cw<CR>')
vim.keymap.set("n", "<F11>", ":silent !start explorer /select,%:p<CR>")
vim.keymap.set("n", "<C-F2>", ":browse edit<cr>")
vim.keymap.set("n", "<F2>", "<Esc>:1,$!xmllint --format -<CR>")
vim.keymap.set("n", "<F12>", "<Esc>:syntax sync fromstart<CR>")
vim.keymap.set("n", "<space>", "za")
vim.keymap.set("v", "<space>", "zf")
vim.keymap.set("n", "<leader>cp", ':let @* = expand("%:p")<cr>', { desc = "Copy Full File Path" })

-- Tmux Navigator
vim.keymap.set("n", "<M-h>", ":TmuxNavigateLeft<cr>", { silent = true })
vim.keymap.set("n", "<M-j>", ":TmuxNavigateDown<cr>", { silent = true })
vim.keymap.set("n", "<M-k>", ":TmuxNavigateUp<cr>", { silent = true })
vim.keymap.set("n", "<M-l>", ":TmuxNavigateRight<cr>", { silent = true })

-- Legacy fzf.vim Mappings (supporting both <leader>V* and <leader>v* namespaces to prevent blocking fzf-lua and snacks.nvim)
vim.keymap.set("n", "<leader>F", ":FzfFiles<CR>", { silent = true, desc = "FZF Files (Vim)" })
vim.keymap.set("n", "<leader>Vf", ":FzfFiles<CR>", { silent = true, desc = "FZF Files (Vim)" })
vim.keymap.set("n", "<leader>Vg", ":FzfRG<CR>", { silent = true, desc = "FZF Ripgrep (Vim)" })
vim.keymap.set("n", "<leader>Vb", ":FzfBuffers<CR>", { silent = true, desc = "FZF Buffers (Vim)" })
vim.keymap.set("n", "<leader>Vt", ":FzfTags<CR>", { silent = true, desc = "FZF Tags (Vim)" })
vim.keymap.set("n", "<leader>Vl", ":FzfLines<CR>", { silent = true, desc = "FZF Lines (Vim)" })
vim.keymap.set("n", "<leader>Vlb", ":FzfBLines<CR>", { silent = true, desc = "FZF Buffer Lines (Vim)" })
vim.keymap.set("n", "<leader>Vtb", ":FzfBTags<CR>", { silent = true, desc = "FZF Buffer Tags (Vim)" })

-- Lowercase <leader>v* aliases (faster typing, avoids Shift delay and accidental Visual mode trigger on timeout)
vim.keymap.set("n", "<leader>vf", ":FzfFiles<CR>", { silent = true, desc = "FZF Files (Vim)" })
vim.keymap.set("n", "<leader>vg", ":FzfRG<CR>", { silent = true, desc = "FZF Ripgrep (Vim)" })
vim.keymap.set("n", "<leader>vb", ":FzfBuffers<CR>", { silent = true, desc = "FZF Buffers (Vim)" })
vim.keymap.set("n", "<leader>vt", ":FzfTags<CR>", { silent = true, desc = "FZF Tags (Vim)" })
vim.keymap.set("n", "<leader>vl", ":FzfLines<CR>", { silent = true, desc = "FZF Lines (Vim)" })
vim.keymap.set("n", "<leader>vlb", ":FzfBLines<CR>", { silent = true, desc = "FZF Buffer Lines (Vim)" })
vim.keymap.set("n", "<leader>vtb", ":FzfBTags<CR>", { silent = true, desc = "FZF Buffer Tags (Vim)" })

-- Note: Snacks.picker (<leader>s*) and Snacks utilities (<leader>h, <leader>z, <leader>lg, <c-/>) keymaps
-- are defined in lua/plugins/init.lua under the snacks.nvim plugin spec to leverage lazy.nvim lazy-loading.


-- NERDTree Mappings
vim.keymap.set("n", "<leader>nn", ":NERDTreeToggle<cr>")
vim.keymap.set("n", "<leader>nb", ":NERDTreeFromBookmark ")
vim.keymap.set("n", "<leader>nf", ":NERDTreeFind<cr>")

-- Dynamic AI Toggle Mapping (<leader>ta)
vim.keymap.set("n", "<leader>ta", function()
  if vim.g.codeium_enabled == 0 or vim.g.codeium_enabled == nil then
    vim.g.codeium_enabled = 1
    pcall(vim.cmd, "Codeium Enable")
    vim.notify("Codeium AI Enabled", vim.log.levels.INFO, { title = "Codeium" })
  else
    vim.g.codeium_enabled = 0
    pcall(vim.cmd, "Codeium Disable")
    vim.notify("Codeium AI Disabled", vim.log.levels.WARN, { title = "Codeium" })
  end
end, { desc = "Toggle Codeium AI" })

-- AI Plugin Inline Mappings
vim.keymap.set("i", "<C-;>", "<Cmd>call codeium#CycleCompletions(1)<CR>")
vim.keymap.set("i", "<C-,>", "<Cmd>call codeium#CycleCompletions(-1)<CR>")
-- <C-]> (Codeium's default) instead of <C-x>, which would shadow the
-- built-in i_CTRL-X completion prefix (^X^F, ^X^O, ^X^L, ...).
vim.keymap.set("i", "<C-]>", "<Cmd>call codeium#Clear()<CR>", { desc = "Codeium: clear suggestion" })

-- Terminal Tool Mappings (Only if not GUI)
if vim.fn.has("gui_running") == 0 then
  vim.keymap.set("n", "<leader>r", ":Ranger<CR>", { silent = true })
  vim.keymap.set("n", "<leader>lf", ":Lf<CR>", { silent = true })
end

-- Vimwiki Shortcuts
vim.keymap.set("n", "<leader>wt", "<Plug>VimwikiMakeDiaryNote", { desc = "Vimwiki Today" })
vim.keymap.set("n", "<leader>x", "<Plug>VimwikiToggleListItem", { desc = "Vimwiki Toggle Checkbox" })
vim.keymap.set("v", "<leader>x", "<Plug>VimwikiToggleListItem", { desc = "Vimwiki Toggle Checkbox" })

-- Functions
vim.cmd([[
function! s:align()
  let p = '^\s*|\s.*\s|\s*$'
  if exists(':Tabularize') && getline('.') =~# '^\s*|' && (getline(line('.')-1) =~# p || getline(line('.')+1) =~# p)
    let column = strlen(substitute(getline('.')[0:col('.')],'[^|]','','g'))
    let position = strlen(matchstr(getline('.')[0:col('.')],'.*|\s*\zs.*'))
    Tabularize/\\\@<!|/l1
    normal! 0
    call search(repeat('[^|]*|',column).'\s\{-\}'.repeat('.',position),'ce',line('.'))
  endif
endfunction
]])

-- Alignment helper keymap
vim.keymap.set("i", "|", "|<Esc>:call <SID>align()<CR>a")
