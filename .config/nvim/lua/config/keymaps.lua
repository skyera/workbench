-- Keymaps (translated from myvimrc)
vim.g.mapleader = "\\" -- Set backslash as leader

-- Formats the current buffer with xmllint.
-- The buffer is replaced only when xmllint succeeds, so a missing tool or
-- malformed input reports an error instead of overwriting the text.
local function format_xml()
    if vim.fn.executable("xmllint") == 0 then
        vim.notify(
            "xmllint not found: install it (Debian/Ubuntu: sudo apt install libxml2-utils)",
            vim.log.levels.ERROR
        )
        return
    end

    local buffer_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local input = table.concat(buffer_lines, "\n") .. "\n"
    local result = vim.system({ "xmllint", "--format", "-" }, { stdin = input, text = true }):wait()

    if result.code ~= 0 then
        local detail = vim.trim(result.stderr or "")
        if detail == "" then
            detail = "no error output"
        end
        vim.notify(
            string.format("xmllint failed (exit %d): %s", result.code, detail),
            vim.log.levels.ERROR
        )
        return
    end

    local output_lines = vim.split(vim.trim(result.stdout), "\n", { plain = true })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, output_lines)
end

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
vim.keymap.set("n", "<F2>", format_xml, { desc = "Format XML with xmllint" })
vim.keymap.set("n", "<F12>", "<Esc>:syntax sync fromstart<CR>")
vim.keymap.set("n", "<space>", "za")
vim.keymap.set("v", "<space>", "zf")
vim.keymap.set("n", "<leader>cp", ':let @* = expand("%:p")<cr>', { desc = "Copy Full File Path" })

-- Remove nvim's default gr* LSP maps (grn, gra, gri, grr, grt, grx). They make
-- our "gr" (references, set on LspAttach) wait for 'timeoutlen' before firing.
-- Rename, code action and implementation stay on <leader>rn, <leader>ca and gi.
for _, key in ipairs({ "grn", "gra", "gri", "grr", "grt", "grx" }) do
    pcall(vim.keymap.del, "n", key)
end
pcall(vim.keymap.del, "x", "gra")

-- Toggle the automatic diagnostic float (see options.lua).
vim.keymap.set("n", "<leader>uf", function()
    vim.g.diagnostic_float_enabled = not vim.g.diagnostic_float_enabled
    local state = vim.g.diagnostic_float_enabled and "on" or "off"
    vim.notify("Diagnostic float: " .. state)
end, { desc = "Toggle diagnostic float" })

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
vim.keymap.set("n", "<leader>VL", ":FzfBLines<CR>", { silent = true, desc = "FZF Buffer Lines (Vim)" })
vim.keymap.set("n", "<leader>VT", ":FzfBTags<CR>", { silent = true, desc = "FZF Buffer Tags (Vim)" })

-- Lowercase <leader>v* aliases (faster typing, avoids Shift delay and accidental Visual mode trigger on timeout)
vim.keymap.set("n", "<leader>vf", ":FzfFiles<CR>", { silent = true, desc = "FZF Files (Vim)" })
vim.keymap.set("n", "<leader>vg", ":FzfRG<CR>", { silent = true, desc = "FZF Ripgrep (Vim)" })
vim.keymap.set("n", "<leader>vb", ":FzfBuffers<CR>", { silent = true, desc = "FZF Buffers (Vim)" })
vim.keymap.set("n", "<leader>vt", ":FzfTags<CR>", { silent = true, desc = "FZF Tags (Vim)" })
vim.keymap.set("n", "<leader>vl", ":FzfLines<CR>", { silent = true, desc = "FZF Lines (Vim)" })
vim.keymap.set("n", "<leader>vL", ":FzfBLines<CR>", { silent = true, desc = "FZF Buffer Lines (Vim)" })
vim.keymap.set("n", "<leader>vT", ":FzfBTags<CR>", { silent = true, desc = "FZF Buffer Tags (Vim)" })

-- Note: Snacks.picker (<leader>s*) and Snacks utilities (<leader>h, <leader>z, <leader>lg, <c-/>) keymaps
-- are defined in lua/plugins/init.lua under the snacks.nvim plugin spec to leverage lazy.nvim lazy-loading.


-- NERDTree Mappings
vim.keymap.set("n", "<leader>nn", ":NERDTreeToggle<cr>")
vim.keymap.set("n", "<leader>nb", ":NERDTreeFromBookmark ")
vim.keymap.set("n", "<leader>nf", ":NERDTreeFind<cr>")

-- Terminal Tool Mappings (Only if not GUI)
if vim.fn.has("gui_running") == 0 then
  vim.keymap.set("n", "<leader>R", ":Ranger<CR>", { silent = true })
  vim.keymap.set("n", "<leader>lf", ":Lf<CR>", { silent = true })
end

-- Vimwiki Shortcuts
vim.keymap.set("n", "<leader>wt", "<Plug>VimwikiMakeDiaryNote", { desc = "Vimwiki Today" })
vim.keymap.set("n", "<leader>x", "<Plug>VimwikiToggleListItem", { desc = "Vimwiki Toggle Checkbox" })
vim.keymap.set("v", "<leader>x", "<Plug>VimwikiToggleListItem", { desc = "Vimwiki Toggle Checkbox" })
