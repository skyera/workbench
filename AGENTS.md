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

*   **One Statement per Line**: Do not pack assignments, calls, branches, or loops onto one line using semicolons or other separators. Expand control flow, including early returns, into clearly indented blocks.
*   **Consistent Formatting & Vertical Paragraphing**: Use consistent indentation, spacing around operators, and blank lines between logical steps. Expanding compact code must not create unbroken vertical walls of code. Break functions longer than 15–20 lines into readable logical paragraphs (e.g., argument validation, data transformation, loops, state updates, resource acquisition/release). Group long branching ladders (such as key event handlers or CLI parsers) into logical clusters separated by blank lines and concise category comments.
*   **Section Dividers**: For substantial single-file tools or modules (>300 lines), use clear 80-column section divider banners (e.g., `--------------------------------------------------------------------------------`) to delineate major layers: constants & FFI, utility helpers, domain/state logic, UI/rendering, host/CLI management, and entry points.
*   **Descriptive Names**: Choose names that explain purpose and units, such as `refresh_interval_seconds` or `process_start_ticks`. Avoid cryptic abbreviations and single-letter names except for small loop indices or conventional local values.
*   **Focused Functions**: Keep functions responsible for one coherent task. Extract complex conditions and repeated operations into named helpers. Prefer early returns to deeply nested branches while keeping each return in a readable block.
*   **Logical File Structure**: Organize files into a short purpose/usage description, imports or dependencies, constants and types, supporting functions, application logic, and a clear entry point, as appropriate. Group related functionality together and keep platform-specific logic easy to locate.
*   **Clear Boundaries**: Separate argument parsing, process or filesystem operations, data transformations, rendering, and input handling. Split modules when this clarifies responsibilities; avoid unnecessary abstraction and tiny forwarding modules.
*   **Readable Data & Expressions**: Expand long argument lists, tables, dictionaries, and compound expressions across lines. Aim for lines under 100 characters where practical. Preserve literal commands, protocol records, and FFI declarations when wrapping would reduce clarity or alter meaning.
*   **Useful Comments**: Explain intent, constraints, resource ownership, and non-obvious platform behavior. Replace obsolete comments when changing code. Avoid comments that merely restate the next line.
*   **Explicit Cleanup**: Make acquisition and release of files, handles, pipes, and subprocesses visible. Keep cleanup and error handling readable rather than hiding them in dense expressions.

### Language Conventions

*   **Lua / LuaJIT**:
    *   Use four spaces for indentation in new files. Expand `if`, `for`, `while`, and function bodies across lines rather than writing inline blocks.
    *   Prefer `local` variables and named functions for substantial logic. Use multiline tables for complex records and state objects.
    *   Keep FFI declarations grouped by API or platform. Name constants instead of scattering unexplained flags and numeric values. Document buffer lifetimes and handle ownership where they matter.
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

For every change, consider how to prove correctness before concluding:
*   **Pre-Implementation Strategy**: Identify test commands, scripts, or reproduction steps *before* writing code.
*   **Automated Tests**: Run test suites (`--test`, unit tests, integration tests). Add new test cases covering the change and edge cases.
*   **Live Verification**: Execute the actual command or utility in the environment to confirm the fix works in practice.
*   **Edge Cases & Regressions**: Test boundary inputs, invalid parameters, error handling, and ensure existing behavior is preserved.
*   **Verification is Mandatory**: Never assume a fix works without running verification commands and inspecting output.

## Request & Issue Workflow

### 1. User Questions, Checks & Diagnostic Inquiries
When the user asks a question, requests a health check, asks for current behavior, or inquires about best practices (e.g., *"check ... server"*, *"is X good?"*, *"what is the current behavior?"*, *"what is the best practice?"*, *"should I change X to Y?"*), the agent MUST:
*   **Non-Destructive Ground-Truth Inspection**: Inspect the live environment, services, sockets, and configurations using read-only commands before answering. Never guess or hallucinate state.
*   **Direct & Transparent Answers**: Answer the user's specific question directly at the start. State clearly whether the system is healthy, failing, or partially degraded.
*   **Root Cause & Objective Analysis**: Clearly explain *why* things behave the way they do, backed by log output or concrete technical facts.
*   **Professional Recommendation & Options**: Present industry best practices with realistic tradeoffs (pros, cons, side effects) and actionable recommendations.
*   **No Unrequested Modifications**: Present potential solutions or improvements as options/proposals. Do NOT modify files or system state during pure diagnostic/question inquiries unless the user explicitly asks to fix or change them.

### 2. Modification, Feature & Fix Requests
When the user asks to implement, modify, fix, or update something (e.g., *"fix ..."*, *"make X do Y"*, *"update ..."*), the agent MUST:

1.  **Think & Analyze**: Explain the root cause or understand the requirement clearly.
2.  **Propose a Solution & Design**: Explain what needs to change, the plan of action, and why. Ensure error handling and user-facing error messages are defined.
3.  **Define Verification / Validation Plan**: Explicitly state how the change will be tested and validated (commands to run, expected results, edge cases).
4.  **Show Mockup UI / Command Output**: If the request involves TUI, GUI, or command output, provide a realistic mockup or sample output preview (including error states if applicable).
5.  **Give Recommendation**: Provide your professional recommendation and options.
6.  **Show Code Comparison / Draft**: Present a before/after diff or draft so the user can see exactly what changes before writing to disk.
7.  **Approval Mode**:
    *   If the user has indicated **"approve always"**, **"do it"**, **"auto approve"**, or explicitly asks to fix/implement directly: proceed immediately with implementation and verification without asking for confirmation.
    *   If the user requests to see a draft or review first (e.g., *"show me the draft"*, *"let me review before commit/modify"*): **display the draft and WAIT for user approval before writing or modifying any files.**
    *   Otherwise: **WAIT for user approval before applying changes or starting implementation.**

## Commit Workflow

*   **One commit per issue**: Each fix should be its own atomic commit with a descriptive message.
*   **"commit"**: When the user says "commit", create the commit(s) locally. Do NOT push.
*   **"push"**: When the user says "push", push all local commits to the remote repository.
*   **"ship"**: When the user says "ship", apply/stage the change(s), create atomic commit(s) locally, and push to the remote repository.
