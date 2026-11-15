# fkill: remaining issues

Open issues in `bin/fkill.lua` after the review and fixes of 2026-11-15.
Line numbers refer to commit `276829b`; they will drift as the file changes.

## Already fixed (for context)

| Commit | What it fixed |
|---|---|
| `7bb3ead` | CLI kill targets are validated; kill-by-name is exact and confirmed |
| `a76a3ab` | Batched keys are kept; force kill is confirmed; crashes restore the terminal |
| `9917058` | Columns align; help works on narrow terminals; resize repaints |
| `155f262` | Tab strip stays whole on narrow terminals |
| `e5f3d71` | Terminal is restored when the TUI receives SIGTERM, SIGHUP, SIGINT or SIGQUIT |
| `bc0d797` | Filter also matches the command line |
| `276829b` | Inspector scroll is bounded; help is scrollable |

## Open issues

Sizes: Trivial is one line, Small is under about 40 lines, Medium is about 60 to 150,
Large is several hundred.

### Behaviour worth fixing first

| # | Issue | Where | Size |
|---|---|---|---|
| 1 | **Stale selections.** A selected process that exits stays in the "(N selected)" count. If its PID is reused, the new process is silently selected. | `:1631`, `:1871` | Small |
| 2 | **Hidden selections are killed.** Selections persist across tabs and filters, so `d` kills selected processes that are not on screen. The prompt says "Kill N selected process(es)?" without naming them. | `:1871` | Small |
| 3 | **"Terminated N" overstates.** It is shown as soon as SIGTERM is sent. A process that ignores or delays SIGTERM still appears in the refreshed list under that message. | kill status line | Small |

Fix 1 and 2 together: prune the selection set on every refresh, and list the names
(or at least the hidden count) in the confirmation prompt.

### Smaller behaviour issues

| # | Issue | Where | Size |
|---|---|---|---|
| 4 | **No auto-refresh.** Memory figures and the list only update on `r`, so a kill acts on a snapshot that may be minutes old. | event loop | Medium |
| 5 | **CLI output is coloured when piped.** `fkill 4194000 2>&1 \| cat -v` shows raw `^[[31m` codes. | non-TUI paths | Small |
| 6 | **User column shows a numeric UID** (`1000`) instead of the user name, except for root. | `:860` | Small |
| 7 | **Command-line matches are invisible below 90 columns.** A row matched by its command line just says `python3`, and there is no inspector at that width. | list rendering | Small |
| 8 | **Inspector wraps the command line by bytes**, so a multi-byte character can be split across two rows. | `:1535` | Small |
| 9 | **Legacy `--fzf` mode** kills the selection with no confirmation and ignores `-9`. | `:2213` | Small |
| 10 | **Heavy tab threshold wording.** The header comment says "> 50 MB"; the code uses `>= 50`. | `:1386` | Trivial |

Auto-refresh (4) needs a decision on the interval; 2 seconds is a reasonable start.
It must keep the cursor on the same PID and pause while a kill prompt is open.

### Platform

| # | Issue | Where | Size |
|---|---|---|---|
| 11 | **macOS is half-supported.** There is a macOS window-size branch, but the terminal, directory and signal-set layouts and `/proc` are Linux-only. It should refuse to start with a clear message. | `:450` | Small |
| 12 | **Windows kill errors are guessed.** A failed kill always reports "Access Denied" or "TerminateProcess failed" without asking the system why. | `:1010`, `:1017` | Small |
| 13 | **Windows leftovers:** the console code page and stderr mode are not restored on exit; resize needs a keypress; CLI modes do not enable colour support before printing colour codes; the inspector re-enumerates every process for each new row. | Windows branches | Medium |

Items 12 and 13 have never been run: there was no Windows host. Whoever fixes them
needs to run `fkill --test` and a manual pass on Windows.

### Maintainability

| # | Issue | Where | Size |
|---|---|---|---|
| 14 | **`run_tui` is one closure of about 570 lines** holding rendering, state and key handling. It can only be tested through a pty. | `:1337` to `:1906` | Large |
| 15 | **Two self-tests check copies of the maths, not the real code**: "Terminal width bounds" and "Vim navigation math". They would pass even if the real code broke. | `:2359`, `:2387` | Small, after 14 |
| 16 | **Style gaps against `AGENTS.md`:** the Windows key reader uses single-line `if`/`elseif` chains; terminal flag values are unnamed numbers (`:395`); `IS_LINUX`, `IS_POSIX`, `bg_match` and `bg_green` are defined but never used. | several | Medium |

Split `run_tui` (14) in two or three commits (state and filtering, rendering, key
handling) with no behaviour change, and rerun every pty check afterwards.

## Not fixable, or not fkill's

- `kill -9` on fkill itself always leaves the terminal broken; SIGKILL cannot be
  intercepted. Run `reset` to recover.
- Three tests in `tests/test_fremote_collector.py` fail. They were failing before
  this work, are unrelated to fkill, and have not been investigated.

## Suggested order

1. Selections (1, 2), then the status wording (3).
2. The small Linux fixes (5 to 10) and macOS fail-fast (11), one commit each.
3. Auto-refresh (4).
4. The `run_tui` split (14), then the self-tests (15) and style pass (16).
5. Windows (12, 13), when a Windows machine is available to test on.

Steps 1 and 2 are low-risk and quick. Step 4 is the bulk of the work.

## How to verify a fix

- `luajit bin/fkill.lua --test` (142 tests passing at `276829b`).
- `python3 -m unittest discover -s tests -k fkill` (5 tests).
- TUI changes need a real terminal or a pty: check 80 and 120 columns, a resize,
  and a short window. Test kills only against throwaway processes, for example a
  copy of `/bin/sleep` under a unique name.
- Never test `fkill -1` or a kill-by-name against a shared name such as `luajit`
  or `systemd` on a live session.
