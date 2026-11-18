# Agent Instructions

For any issue, feature request, review, or modification task, the agent MUST follow this workflow:

1.  **Research & Think**: Analyze the request (including any review notes), explore the relevant parts of the codebase, and identify the root cause or optimal design for the change.
2.  **Design & Plan**: Formulate a clear plan of action and verification strategy.
    *   **Verification Strategy**: For every change, **ALWAYS consider and define how to verify/validate the change** (e.g., test suites, manual verification commands, edge-case checks) before writing code.
    *   **UI / Command Mockup**: If the task involves a TUI, GUI, or command output, **ALWAYS show a visual mockup UI or sample output preview**.
    *   **Error Handling**: Account for failure scenarios and ensure the user receives clear, actionable error messages explaining why an action failed.
    *   **Recommendation**: Give clear, actionable recommendations with rationale.
    *   **ALWAYS show the user the plan/design before making any code changes.**
3.  **Approval Gate**: Wait for user approval before starting implementation (unless the user has indicated auto-approval).
4.  **Implement**: Perform surgical and idiomatic changes to the codebase directly. Ensure robust error handling with transparent, informative error messages.
5.  **Verify**: Validate the changes through testing, manual verification, or relevant shell commands to ensure the solution is correct and does not introduce regressions. Double check and verify every fix/solution thoroughly before concluding.

Verification is the only path to finality. Do not assume success. Always double check and verify every fix or solution for correctness.

## Code Readability & Organization

These rules apply to new and modified code, including Lua, Python, shell scripts,
PowerShell, batch files, embedded scripts, and test fixtures. Prefer readable,
well-organized code over compact code.

### General Rules

*   **One Statement per Line**: Do not pack assignments, calls, branches, or loops onto one line using semicolons or other separators. Expand control flow, including early returns, into clearly indented blocks (Lua has two narrow exceptions, listed under Language Conventions).
*   **Consistent Formatting & Vertical Paragraphing**: Use consistent indentation, spacing around operators, and blank lines between logical steps. Expanding compact code must not create unbroken vertical walls of code. Break functions longer than 15–20 lines into readable logical paragraphs (e.g., argument validation, data transformation, loops, state updates, resource acquisition/release). Group long branching ladders (such as key event handlers or CLI parsers) into logical clusters separated by blank lines and concise category comments.
*   **Section Dividers**: For substantial single-file tools or modules (>300 lines), use clear 80-column section divider banners (e.g., `--------------------------------------------------------------------------------`) to delineate major layers: constants & FFI, utility helpers, domain/state logic, UI/rendering, host/CLI management, and entry points.
*   **Descriptive Names**: Choose names that explain purpose and units, such as `refresh_interval_seconds` or `process_start_ticks`. Avoid cryptic abbreviations and single-letter names except for small loop indices or conventional local values.
*   **Self-Explaining Function Names**: A function's name should tell a reader what it does without opening it.
    *   Use a verb plus an object that states the action and its target: `load_config`, `parse_git_status`, `render_log_panel`. Name predicates `is_`/`has_`/`should_` (`is_valid_handle`).
    *   Avoid vague names such as `handle`, `process`, `do_work`, `helper`, `run2`, `misc`, or names that only state the type (`get_data`, `do_string`).
    *   Name side effects in the verb: `delete_`, `write_`, `kill_`, `stop_` for changes; `get_`, `find_`, `count_`, `format_` must not modify state.
    *   If a function does more than its name says, rename or split it rather than hiding the extra work.
    *   Add a comment above the function when the name cannot carry it all: units, what it returns on failure (`nil, err`), side effects, or why it exists.

    ```lua
    -- Bad
    local function handle(p)        -- handle what? returns what?

    -- Good
    -- Stops the given Windows services; returns the names it actually stopped.
    local function stop_update_services(service_names)
    ```
*   **Focused Functions**: Keep functions responsible for one coherent task. Extract complex conditions and repeated operations into named helpers. Prefer early returns to deeply nested branches while keeping each return in a readable block.
*   **Logical File Structure**: Organize files into a short purpose/usage description, imports or dependencies, constants and types, supporting functions, application logic, and a clear entry point, as appropriate. Group related functionality together and keep platform-specific logic easy to locate.
*   **Clear Boundaries**: Separate argument parsing, process or filesystem operations, data transformations, rendering, and input handling. Split modules when this clarifies responsibilities; avoid unnecessary abstraction and tiny forwarding modules.
*   **Readable Data & Expressions**: Expand long argument lists, tables, dictionaries, and compound expressions across lines. Keep source code and script lines to at most 80 characters where possible. Preserve literal commands, protocol records, and FFI declarations when wrapping would reduce clarity or alter meaning.
*   **Useful Comments**: Explain intent, constraints, resource ownership, and non-obvious platform behavior. Replace obsolete comments when changing code. Avoid comments that merely restate the next line.
*   **Explicit Cleanup**: Make acquisition and release of files, handles, pipes, and subprocesses visible. Keep cleanup and error handling readable rather than hiding them in dense expressions.

### Language Conventions

*   **Lua / LuaJIT**:
    *   Use four spaces for indentation in new files. The Neovim config (`.config/nvim`) is the exception: it uses two spaces, the Neovim convention. `.editorconfig` files set both widths.
    *   **No single-line blocks**, with two exceptions: (1) a callback whose whole body is one call or one `return` expression (e.g. `function() Snacks.zen() end`); (2) a short guard (`if cond then return end`, `break`, `goto continue`) with no `else`, within 80 columns. Everything else is expanded: never put the body of an `if`, `for`, `while`, `repeat` or multi-statement `function` on the same line as its header, and `elseif` and `else` each start their own line.
    *   **Maximum line length is 80 characters**: This is a hard limit for Lua,
        not a target. Wrap long calls, argument lists, tables, conditions, and
        string concatenations across lines, one item per line where that helps.
        The only exceptions are literal FFI `cdef` declarations, URLs, and
        string literals that cannot be split without changing their meaning.
    *   **One statement per line, no semicolons**: Never use `;` in Lua. Do not
        join statements with it (`step = 1; width = 1`), do not end statements
        with it (`local count = 0;`), and do not use it as a table field
        separator (write `{ a = 1, b = 2 }`, not `{ a = 1; b = 2 }`). FFI C
        declarations inside `ffi.cdef[[ ... ]]` are C code and keep their `;`.
    *   **Small functions**: Each function does one job that its name states.
        *   Aim for 30 lines or fewer. Over 50 lines means split it.
        *   Nest blocks at most 3 levels deep. Use early returns and named
            helpers to flatten deeper logic.
        *   Take at most 4 parameters. Pass an options table beyond that.
        *   Keep one level of detail per function: a top-level function
            calls named steps and doesn't mix them with low-level byte or
            string handling.
        *   Extract loop bodies, complex conditions, string building, and
            repeated logic into named `local` helpers.
    *   **Clean, easy-to-read code**: Write code a new reader can follow
        top to bottom without jumping around.
        *   Use names that read as plain English: verbs for functions
            (`load_config`, `render_row`) and nouns for values. Name
            booleans `is_`/`has_`/`should_`.
        *   Give magic numbers and repeated strings named constants.
        *   No globals. Declare everything `local`, as close to its first
            use as possible.
        *   Delete dead code, commented-out code, and unused variables
            instead of leaving them.
        *   Prefer a clear, slightly longer version over a clever one-liner
            (for example, no chained `a and b or c` with complex operands).
    *   **Comment code that does not explain itself**: First try to make the
        code clear with better names and smaller helpers. Where it still is
        not obvious, add a comment.
        *   **What**: Above each non-trivial function, say in one or two lines
            what it does, what it takes, and what it returns (including
            `nil, err` on failure).
        *   **What**: Above a dense block (a parsing step, an escape sequence,
            bit flags, a tricky pattern), say what it produces.
        *   **Why**: Explain reasons the code alone cannot show: platform
            quirks, workarounds, magic numbers, ordering constraints, FFI
            struct layouts, buffer or handle ownership, and rejected
            simpler approaches.
        *   **Skip** comments that only repeat the code
            (`-- increment i` above `i = i + 1`).
        *   **Keep them true**: Update or delete a comment whenever the code
            it describes changes.
    *   Prefer `local` variables and named functions for substantial logic. Use multiline tables for complex records and state objects.
    *   Keep FFI declarations grouped by API or platform. Name constants instead of scattering unexplained flags and numeric values (e.g., `local O_RDWR = 2`, `local WNOHANG = 1`).

    ```lua
    -- Bad
    local function file_exists(path)
        local f = io.open(path, "r")
        if f then f:close() return true end
        return false
    end
    for _, item in ipairs(list) do item.enabled = true end

    -- Good
    -- Returns true when `path` exists and can be opened for reading.
    local function file_exists(path)
        local file = io.open(path, "r")
        if not file then
            return false
        end

        file:close()
        return true
    end

    for _, item in ipairs(list) do
        item.enabled = true
    end
    ```

    ```lua
    -- Bad
    local width = 80; local height = 24;
    local function show(p) io.write(fmt(p):sub(1, 77) .. "...", "\n") end

    -- Good
    local MAX_ROW_WIDTH = 80
    local ELLIPSIS = "..."

    -- Truncates `text` to `max_width` columns, ending it with an ellipsis.
    local function truncate(text, max_width)
        if #text <= max_width then
            return text
        end

        -- Reserve room for the ellipsis so the row never exceeds max_width.
        return text:sub(1, max_width - #ELLIPSIS) .. ELLIPSIS
    end

    -- Formats one process record as a fixed-width table row.
    local function format_process_row(process)
        return string.format(
            "%6d  %-20s %5.1f%%  %s",
            process.pid,
            process.name,
            process.cpu_percent,
            process.command
        )
    end

    -- Writes one process row, truncated and with any old text erased.
    local function print_process_row(process)
        local row = format_process_row(process)
        io.write(truncate(row, MAX_ROW_WIDTH))

        -- Emit a color reset before erasing to end of line: Windows Console
        -- fills erased cells with the active background color otherwise.
        io.write("\27[0m\27[K\n")
    end
    ```
*   **Python**:
    *   Use four spaces for indentation and standard Python naming and import organization. Put module and class responsibilities in concise docstrings when helpful.
    *   Use context managers for resources where appropriate. Specify encodings for text files and subprocess text when the encoding is known, including UTF-8 source files and protocol data.
    *   Keep embedded Lua, shell, or collector scripts formatted as readable source, not compressed strings. Preserve their quoting and runtime behavior.
*   **Shell (`sh` / `bash`)**:
    *   Use four spaces for indentation in new files. Keep conditionals, loops, and functions in expanded blocks, with one logical command per line.
    *   Quote variable expansions and paths appropriately. Use arrays for argument lists in Bash; use POSIX-compatible constructs in scripts whose shebang selects `sh`.
    *   Split long pipelines or commands at logical boundaries using valid continuations. Do not change shell dialect or introduce `set -e` solely as part of formatting.
*   **PowerShell & Windows Batch**:
    *   Use consistent indentation and expanded control blocks. Give variables and labels descriptive names, and group setup, argument parsing, work, and cleanup clearly.
    *   Preserve native quoting rules, delayed-expansion behavior, exit codes, and error streams. Do not compress commands or add fragile continuations merely to meet a line-length target.

### Formatting & Verification

*   Apply these rules as code is written; do not leave readability as optional follow-up work.
*   Keep formatting changes within the task's scope. Avoid unrelated repository-wide formatting and keep broad formatting-only changes separate from behavior changes.
*   Use existing formatter configuration when available. Do not introduce a mandatory formatter dependency without a task-related reason.
*   **Preserve Structural Comment Invariants**: Never rename, move, or delete structural lifecycle marker comments (e.g., `-- Command-line entry point.`, `-- FFI Declarations`) that test harnesses, loaders, or build scripts inspect or split on.
*   Before finishing, review the diff and run `git diff --check`, plus relevant syntax checks and tests for changed executable code. For formatting-only changes, explicitly verify that quoting, embedded scripts, and behavior remain intact.

## Error Handling & Diagnostic Guidelines

When designing and implementing logic across utilities, TUIs, scripts, and commands:
*   **Never Swallow or Mask Errors**: Never replace detailed command or system errors with generic failure notices (e.g., don't just say "Failed"; capture and report the actual command error).
*   **Show Clear Error Messages Explaining "Why"**: Always state exactly what failed and why (e.g., ref not found, branch not fully merged, permission denied, invalid argument).
*   **Provide Actionable Guidance**: When an action cannot proceed, tell the user how to resolve it (e.g., "Use 'D' to force delete unmerged branches", "Run 'git checkout <branch>' first").
*   **Verify Error Paths**: Include error and edge-case scenarios in the verification plan to confirm the user sees the expected diagnostic message when things fail.

## Cross-Platform & Terminal (TUI) Guidelines

When building or modifying CLI utilities, TUIs, scripts, and subprocess wrappers:
*   **Windows `cmd.exe` Command Quoting**:
    *   Never use single quotes (`'...'`) for command arguments containing shell operators (`|`, `&`, `<`, `>`, `^`, `%`) when invoked via `popen` or shell execution on Windows. `cmd.exe` does not recognize single quotes and will treat `|` as a shell pipeline.
    *   Always use escaped double quotes: e.g. `git log --format=\"%h|%an|%cr|%s\"`.
*   **Dual Stream Console Initialization (`stdout` & `stderr`)**:
    *   When configuring Windows virtual terminal processing (`ENABLE_VIRTUAL_TERMINAL_PROCESSING` / `0x0004`), explicitly apply it to **both** `stdout` (`STD_OUTPUT_HANDLE` / `-11`) and `stderr` (`STD_ERROR_HANDLE` / `-12`) if ANSI escape sequences can be output to either stream.
*   **Console Input Mode Flags with `_getch()`**:
    *   Do not enable `ENABLE_WINDOW_INPUT` (0x0008) when reading characters with standard C runtime `_getch()`. Window move/resize/focus events enter the input buffer and corrupt or delay character reads.
*   **Erase to End-of-Line (`\27[K`) Hygiene**:
    *   Always emit `\27[0m` (color reset) immediately before `\27[K`. Many terminal emulators (especially Windows Console) fill erased cells using the currently active background color, causing selection highlights to bleed across the screen.
*   **Viewport & Buffer Shrink Cleanup**:
    *   When an item is deleted or live filtering reduces row count, clamp the scroll viewport so the view never gets stuck on empty rows, and explicitly clear orphaned rows with `\27[%d;1H\27[K`.

## Verification & Validation Guidelines

For every change, define how it will be proven correct *before* writing code,
and choose the method that fits what changed:

| Change type            | Minimum verification                                         |
|------------------------|--------------------------------------------------------------|
| Bug fix                | Reproduce the failure first; show it passes after the fix    |
| New behavior / feature | Add a test; run the real command and inspect its output      |
| Error handling         | Trigger the failure; confirm the exact message shown         |
| TUI / rendering        | Run it in a terminal; check resize, shrink, and cleanup      |
| Refactor / formatting  | Existing tests unchanged; `git diff --check`; no behavior diff |
| Docs / config only     | Syntax or lint check; confirm the file is still parsed       |

*   **Pre-Implementation Strategy**: Identify test commands, scripts, or reproduction steps *before* writing code.
*   **Automated Tests**: Run the narrowest relevant test first, then the full suite (`--test`, unit tests, integration tests). Add new test cases covering the change and edge cases.
*   **Live Verification**: Execute the actual command or utility in the environment to confirm the fix works in practice.
*   **Edge Cases & Regressions**: Test boundary inputs, invalid parameters, error handling, and ensure existing behavior is preserved.
*   **Verification is Mandatory**: Never assume a fix works without running verification commands and inspecting output.
*   **Report Evidence**: End each task with a `Verified:` block listing the real commands run and their results, taken from actual output (never assumed).
*   **If Something Cannot Be Verified** (e.g. Windows-only code on Linux), state exactly what was not verified and why. Never describe it as passing.

    ```
    Verified:     python3 dotag.py --test   -> 42 passed, 0 failed
    Verified:     dotag.py /nonexistent     -> "error: path not found: /nonexistent"
    Not verified: Windows console path (no Windows host available)
    ```

## Request & Issue Workflow

### 0. Default Response for Questions, Features & New Functions
When the user asks a question, requests a feature, or asks for a new function or command, the agent MUST respond in this order and then stop:

1.  **Think**: Analyze the request and the relevant code first. State the problem or requirement in a few sentences.
2.  **Design**: Show the proposed design: what changes, where (files/functions), and how it works, including error handling.
3.  **Recommendation**: Give one clear recommendation with rationale. Mention alternatives only briefly, with their tradeoffs.
4.  **Mockup UI / Sample Output**: For any TUI, GUI, or command output, show a realistic mockup, including error states.
5.  **Ask for Approval**: End by explicitly asking the user to approve (e.g., *"Approve? Reply 'doit' to implement or 'ship' to implement, verify, commit, and push."*). Do NOT modify files until the user approves.

### 1. User Questions, Checks & Diagnostic Inquiries
When the user asks a question, requests a health check, asks for current behavior, or inquires about best practices (e.g., *"check ... server"*, *"is X good?"*, *"what is the current behavior?"*, *"what is the best practice?"*, *"should I change X to Y?"*), the agent MUST:
*   **Non-Destructive Ground-Truth Inspection**: Inspect the live environment, services, sockets, and configurations using read-only commands before answering. Never guess or hallucinate state.
*   **Direct & Transparent Answers**: Answer the user's specific question directly at the start. State clearly whether the system is healthy, failing, or partially degraded.
*   **Root Cause & Objective Analysis**: Clearly explain *why* things behave the way they do, backed by log output or concrete technical facts.
*   **Show the Investigation Trail**: List the decisive commands used to reach the conclusion, each with a one-line result, so the user can rerun them and troubleshoot on their own (see Request & Issue Workflow, section 2).
*   **Professional Recommendation & Options**: Present industry best practices with realistic tradeoffs (pros, cons, side effects) and actionable recommendations.
*   **No Unrequested Modifications**: Present potential solutions or improvements as options/proposals. Do NOT modify files or system state during pure diagnostic/question inquiries unless the user explicitly asks to fix or change them.

### 2. Modification, Feature & Fix Requests
When the user asks to implement, modify, fix, or update something (e.g., *"fix ..."*, *"make X do Y"*, *"update ..."*), the agent MUST:

1.  **Think & Analyze**: Explain the root cause or understand the requirement clearly.
    *   **Show the Investigation Trail**: Before stating a root cause, list the decisive commands used to find it (reproduction, grep/search, log or state inspection), each with a one-line result. Keep them copy-pasteable and in order. Skip noise; keep dead ends only when they ruled out a likely suspect. Finish with a short "Troubleshoot it yourself" tip. If the cause is not confirmed, label it **Hypothesis** and give the command that would confirm it.
2.  **Propose a Solution & Design**: Explain what needs to change, the plan of action, and why. Ensure error handling and user-facing error messages are defined.
3.  **Define Verification / Validation Plan**: Explicitly state how the change will be tested and validated (commands to run, expected results, edge cases).
4.  **Show Mockup UI / Command Output**: If the request involves TUI, GUI, or command output, provide a realistic mockup or sample output preview (including error states if applicable).
5.  **Give Recommendation**: Provide your professional recommendation and options.
6.  **Show Code Comparison / Draft**: Present a before/after diff or draft so the user can see exactly what changes before writing to disk.
7.  **Approval Mode**:
    *   **"next"**: Move to the next open issue and present it for review only. Show, in order: (1) **Problem**: what the user sees, with a reproduction or evidence; (2) **Investigation**: the decisive commands run and what each showed; (3) **Root Cause**: why it happens, with `file:line` references; (4) **Solution**: the proposed fix, error handling, and verification plan; (5) **Code Change**: a before/after diff of the exact code to change. Then ask for approval (*"Approve? Reply 'doit' or 'ship'."*). "next" is NOT approval: do not modify files.
    *   **"doit"** / **"do it"**: Treat as approval. Proceed immediately with implementation and verification without asking for confirmation. Do not commit or push unless also asked.
    *   **"ship"**: Treat as approval for the whole flow: implement, verify, commit, and push, without stopping to ask (see Commit Workflow).
    *   **"fix it"** / **"fix #N"**: Same as "ship": implement, verify, commit, and push, without stopping to ask.
    *   If the user has indicated **"approve always"**, **"auto approve"**, or explicitly asks to implement directly: proceed immediately with implementation and verification without asking for confirmation.
    *   If the user requests to see a draft or review first (e.g., *"show me the draft"*, *"let me review before commit/modify"*): **display the draft and WAIT for user approval before writing or modifying any files.**
    *   Otherwise: **WAIT for user approval before applying changes or starting implementation.**

## Commit Workflow

*   **One commit per issue**: Each fix should be its own atomic commit with a descriptive message.
*   **"commit"**: When the user says "commit", create the commit(s) locally. Do NOT push.
*   **"push"**: When the user says "push", push all local commits to the remote repository.
*   **"ship"**: When the user says "ship", it means approve + implement + verify + commit + push. Implement the proposed change(s) if not yet applied, run the verification plan, and only if verification passes, create atomic commit(s) locally and push to the remote repository. If verification fails, stop, report the failure output, and do not commit or push.
*   **"fix it"** / **"fix #N"**: Same as "ship".
*   **Show the Result**: After any commit or push ("commit", "push", "ship", "fix it"), end the response with a short status block proving it happened, taken from real command output (never assumed):

    ```
    Committed: 061c9b2 fix(dotag): honor .gitignore by listing files with git ls-files
    Pushed:    6363829..061c9b2  master -> master
    Branch:    master...origin/master (in sync, working tree clean)
    ```

    If a step did not happen (e.g., commit only, push failed, verification failed), say so explicitly in the block with the error output.
