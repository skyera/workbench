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

When the user asks about an issue, problem, feature, or modification, the agent MUST:

1.  **Think & Analyze**: Explain the root cause or understand the requirement clearly.
2.  **Propose a Solution & Design**: Explain what needs to change, the plan of action, and why. Ensure error handling and user-facing error messages are defined.
3.  **Define Verification / Validation Plan**: Explicitly state how the change will be tested and validated (commands to run, expected results, edge cases).
4.  **Show Mockup UI / Command Output**: If the request involves TUI, GUI, or command output, provide a realistic mockup or sample output preview (including error states if applicable).
5.  **Give Recommendation**: Provide your professional recommendation and options.
6.  **Show Code Comparison**: Present a before/after diff so the user can see exactly what changes.
7.  **Approval Mode**:
    *   If the user has indicated **"approve always"**, **"do it"**, **"auto approve"**, or explicitly asks to fix/implement directly: proceed immediately with implementation and verification without asking for confirmation.
    *   Otherwise: **WAIT for user approval before applying changes or starting implementation.**

## Commit Workflow

*   **One commit per issue**: Each fix should be its own atomic commit with a descriptive message.
*   **"commit"**: When the user says "commit", create the commit(s) locally. Do NOT push.
*   **"push"**: When the user says "push", push all local commits to the remote repository.
*   **"ship"**: When the user says "ship", apply/stage the change(s), create atomic commit(s) locally, and push to the remote repository.
