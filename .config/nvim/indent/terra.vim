" Vim indent file
" Language:    Terra (terralang.org)
" Description: Provides indentation logic for Terra functions, structs, and Lua constructs.

" Only load this indent file when no other was loaded.
if exists("b:did_indent")
    finish
endif
let b:did_indent = 1

setlocal indentexpr=GetTerraIndent()
setlocal indentkeys+=0=end,0=until,0=},0=],0=else,0=elseif
setlocal nocindent
setlocal autoindent

let b:undo_indent = "setlocal autoindent< cindent< indentexpr< indentkeys<"

" Only define the indentation function once.
if exists("*GetTerraIndent")
    finish
endif

function! GetTerraIndent()
    let l:ignorecase_save = &ignorecase
    try
        let &ignorecase = 0
        return s:GetTerraIndentIntern()
    finally
        let &ignorecase = l:ignorecase_save
    endtry
endfunction

function! s:GetTerraIndentIntern()
    " Find the closest non-blank line above the current line.
    let l:prevlnum = prevnonblank(v:lnum - 1)
    if l:prevlnum == 0
        return 0
    endif

    let l:ind = indent(l:prevlnum)
    let l:prevline = getline(l:prevlnum)

    " Check if the previous line starts a block:
    " Control flow keywords: if, for, while, repeat, else, elseif, do, then, quote
    let l:midx = match(l:prevline, '^\s*\%(if\>\|for\>\|while\>\|repeat\>\|else\>\|elseif\>\|do\>\|then\>\|quote\>\)')

    " Opening braces or parentheses at the end of the line (e.g. struct Point {, table definitions)
    if l:midx == -1
        let l:midx = match(l:prevline, '\%({\|(\)\s*\%(--\%([^[].*\)\?\)\?$')
    endif

    " Function and Terra block declarations (e.g. terra add(a : int) : int, function foo())
    if l:midx == -1
        let l:midx = match(l:prevline, '\<\%(function\|terra\)\>\s*\%(\k\|[.:]\)\{-}\s*(')
    endif

    " Increase indent if block opener found, not in a comment, and not closed on same line
    if l:midx != -1
        let l:is_comment = synIDattr(synIDtrans(synID(l:prevlnum, l:midx + 1, 1)), "name") ==? "Comment"
        if !l:is_comment && l:prevline !~ '\<end\>\|\<until\>'
            let l:ind = l:ind + shiftwidth()
        endif
    endif

    " Decrease indent on closing constructs on the current line:
    " end, else, elseif, until, }, )
    let l:midx = match(getline(v:lnum), '^\s*\%(end\>\|else\>\|elseif\>\|until\>\|}\|)\)')
    if l:midx != -1
        let l:is_comment = synIDattr(synIDtrans(synID(v:lnum, l:midx + 1, 1)), "name") ==? "Comment"
        if !l:is_comment
            let l:ind = l:ind - shiftwidth()
        endif
    endif

    return l:ind < 0 ? 0 : l:ind
endfunction
