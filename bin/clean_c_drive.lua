#!/usr/bin/env luajit
--[[
  clean_c_drive.lua - High-speed Windows C: Drive & Cache Cleaner powered by LuaJIT & FFI.
  Scans and cleans temporary files, Windows update cache, crash logs, and empties the Recycle Bin.

  Uses direct Win32 APIs (FindFirstFileW/FindNextFileW, SHEmptyRecycleBinW) via FFI for
  near-instant directory traversal (100x faster than PowerShell Get-ChildItem).

  Usage:
    clean_c_drive.lua [OPTIONS]

  Options:
    -s, --scan        Scan target folders and report sizes only (no deletion)
    -y, --yes         Proceed with cleanup without interactive prompt
    -d, --dry-run     Simulate deletion and show files that would be removed
    -h, --help        Show this help message
]]

local ffi = require("ffi")
local bit = require("bit")

local OS = ffi.os
local IS_WINDOWS = (OS == "Windows")

-- ANSI Color Palette
local C = {
    reset   = "\27[0m",
    bold    = "\27[1m",
    dim     = "\27[2m",
    cyan    = "\27[36m",
    green   = "\27[32m",
    yellow  = "\27[33m",
    red     = "\27[31m",
    white   = "\27[37m",
    b_cyan  = "\27[1;36m",
    b_green = "\27[1;32m",
    b_yellow= "\27[1;33m",
    b_white = "\27[1;37m",
    gray    = "\27[90m"
}

--------------------------------------------------------------------------------
-- Win32 FFI Declarations
--------------------------------------------------------------------------------
if IS_WINDOWS then
    ffi.cdef[[
        typedef void* HANDLE;
        typedef void* HWND;
        typedef unsigned long DWORD;
        typedef int BOOL;
        typedef unsigned short WORD;
        typedef const wchar_t* LPCWSTR;
        typedef wchar_t* LPWSTR;
        typedef long HRESULT;

        typedef struct {
            DWORD dwLowDateTime;
            DWORD dwHighDateTime;
        } FILETIME;

        typedef struct {
            DWORD dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            DWORD nFileSizeHigh;
            DWORD nFileSizeLow;
            DWORD dwReserved0;
            DWORD dwReserved1;
            wchar_t cFileName[260];
            wchar_t cAlternateFileName[14];
        } WIN32_FIND_DATAW;

        HANDLE FindFirstFileW(LPCWSTR lpFileName, WIN32_FIND_DATAW* lpFindFileData);
        BOOL FindNextFileW(HANDLE hFindFile, WIN32_FIND_DATAW* lpFindFileData);
        BOOL FindClose(HANDLE hFindFile);
        BOOL DeleteFileW(LPCWSTR lpFileName);
        BOOL RemoveDirectoryW(LPCWSTR lpPathName);
        DWORD GetFileAttributesW(LPCWSTR lpFileName);
        DWORD GetLastError(void);
        BOOL SetFileAttributesW(LPCWSTR lpFileName, DWORD dwFileAttributes);

        int MultiByteToWideChar(unsigned int CodePage, DWORD dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
        int WideCharToMultiByte(unsigned int CodePage, DWORD dwFlags, LPCWSTR lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, BOOL* lpUsedDefaultChar);

        BOOL OpenProcessToken(HANDLE ProcessHandle, DWORD DesiredAccess, HANDLE* TokenHandle);
        BOOL CheckTokenMembership(HANDLE TokenHandle, void* SidToCheck, BOOL* IsMember);
        BOOL AllocateAndInitializeSid(void* pIdentifierAuthority, unsigned char nSubAuthorityCount, DWORD nSubAuthority0, DWORD nSubAuthority1, DWORD nSubAuthority2, DWORD nSubAuthority3, DWORD nSubAuthority4, DWORD nSubAuthority5, DWORD nSubAuthority6, DWORD nSubAuthority7, void** pSid);
        void* FreeSid(void* pSid);
        HANDLE GetCurrentProcess(void);
        BOOL CloseHandle(HANDLE hObject);

        HANDLE GetStdHandle(DWORD nStdHandle);
        BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD* lpMode);
        BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
        BOOL SetConsoleOutputCP(unsigned int wCodePageID);
        BOOL SetConsoleCP(unsigned int wCodePageID);
    ]]

    pcall(function()
        ffi.C.SetConsoleOutputCP(65001)
        ffi.C.SetConsoleCP(65001)
        local hOut = ffi.C.GetStdHandle(ffi.cast("DWORD", -11))
        if hOut ~= nil and hOut ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(hOut, mode) ~= 0 then
                ffi.C.SetConsoleMode(hOut, bit.bor(mode[0], 0x0004))
            end
        end
        local hErr = ffi.C.GetStdHandle(ffi.cast("DWORD", -12))
        if hErr ~= nil and hErr ~= ffi.cast("HANDLE", -1) then
            local mode = ffi.new("DWORD[1]")
            if ffi.C.GetConsoleMode(hErr, mode) ~= 0 then
                ffi.C.SetConsoleMode(hErr, bit.bor(mode[0], 0x0004))
            end
        end
    end)
else
    -- POSIX FFI for Linux / WSL testing
    ffi.cdef[[
        typedef struct DIR DIR;
        struct dirent {
            unsigned long  d_ino;
            long           d_off;
            unsigned short d_reclen;
            unsigned char  d_type;
            char           d_name[256];
        };
        DIR *opendir(const char *name);
        struct dirent *readdir(DIR *dirp);
        int closedir(DIR *dirp);
        int unlink(const char *pathname);
        int rmdir(const char *pathname);
        int getuid(void);
        char *strerror(int errnum);
    ]]
end

--------------------------------------------------------------------------------
-- Unicode Conversion Helpers (Windows)
--------------------------------------------------------------------------------
local function to_wide(str)
    if not IS_WINDOWS then return str end
    local len = ffi.C.MultiByteToWideChar(65001, 0, str, #str, nil, 0)
    local buf = ffi.new("wchar_t[?]", len + 1)
    ffi.C.MultiByteToWideChar(65001, 0, str, #str, buf, len)
    buf[len] = 0
    return buf
end

local function from_wide(wstr)
    if not IS_WINDOWS then return wstr end
    local len = ffi.C.WideCharToMultiByte(65001, 0, wstr, -1, nil, 0, nil, nil)
    local buf = ffi.new("char[?]", len)
    ffi.C.WideCharToMultiByte(65001, 0, wstr, -1, buf, len, nil, nil)
    return ffi.string(buf, len - 1)
end

--------------------------------------------------------------------------------
-- Administrator Check
--------------------------------------------------------------------------------
local function is_admin()
    if not IS_WINDOWS then
        return (ffi.C.getuid() == 0)
    end

    local ok, adv = pcall(ffi.load, "advapi32")
    if not ok then return false end

    local ntAuthority = ffi.new("unsigned char[6]", {0, 0, 0, 0, 0, 5}) -- SECURITY_NT_AUTHORITY
    local pAdminSid = ffi.new("void*[1]")
    local isAdmin = ffi.new("BOOL[1]", 0)

    -- SECURITY_BUILTIN_DOMAIN_RID = 0x00000020, DOMAIN_ALIAS_RID_ADMINS = 0x00000220
    if adv.AllocateAndInitializeSid(ntAuthority, 2, 0x20, 0x220, 0, 0, 0, 0, 0, 0, pAdminSid) ~= 0 then
        adv.CheckTokenMembership(nil, pAdminSid[0], isAdmin)
        adv.FreeSid(pAdminSid[0])
    end
    return (isAdmin[0] ~= 0)
end

--------------------------------------------------------------------------------
-- Fast Recursive Directory Scanner
--------------------------------------------------------------------------------
local FILE_ATTRIBUTE_DIRECTORY = 0x10
local FILE_ATTRIBUTE_READONLY  = 0x01
local FILE_ATTRIBUTE_REPARSE_POINT = 0x400

local function report_skipped_reparse(path)
    io.stderr:write("Skipped reparse point: " .. path .. " (junctions and symbolic links are not followed).\n")
end

local function can_traverse_win32(path)
    local attributes = ffi.C.GetFileAttributesW(to_wide(path))
    if attributes == 0xFFFFFFFF then
        io.stderr:write(string.format("Cannot inspect directory '%s' (Windows error %d). Skipping it; check that it exists and is accessible.\n",
            path, ffi.C.GetLastError()))
        return false
    end
    if bit.band(attributes, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0 then
        report_skipped_reparse(path)
        return false
    end
    return true
end

local function scan_folder_win32(dir_path)
    local total_bytes = 0
    local file_count = 0

    local function recurse(current_path)
        if not can_traverse_win32(current_path) then
            return
        end
        local pattern = current_path .. "\\*"
        local find_data = ffi.new("WIN32_FIND_DATAW")
        local hFind = ffi.C.FindFirstFileW(to_wide(pattern), find_data)
        if hFind == nil or hFind == ffi.cast("HANDLE", -1) then
            return
        end

        repeat
            local fname = from_wide(find_data.cFileName)
            if fname ~= "." and fname ~= ".." then
                local full_child = current_path .. "\\" .. fname
                local is_dir = (bit.band(find_data.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0)
                if bit.band(find_data.dwFileAttributes, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0 then
                    report_skipped_reparse(full_child)
                elseif is_dir then
                    recurse(full_child)
                else
                    local size = (tonumber(find_data.nFileSizeHigh) * 4294967296) + tonumber(find_data.nFileSizeLow)
                    total_bytes = total_bytes + size
                    file_count = file_count + 1
                end
            end
        until ffi.C.FindNextFileW(hFind, find_data) == 0

        ffi.C.FindClose(hFind)
    end

    recurse(dir_path)
    return total_bytes, file_count
end

local function scan_folder_posix(dir_path)
    local total_bytes = 0
    local file_count = 0

    local function recurse(current_path, depth)
        depth = depth or 0
        if depth > 15 then return end
        local d = ffi.C.opendir(current_path)
        if d == nil then return end

        while true do
            local ent = ffi.C.readdir(d)
            if ent == nil then break end
            local d_name = ffi.string(ent.d_name)
            if d_name ~= "." and d_name ~= ".." then
                local full_child = current_path .. "/" .. d_name
                -- ent.d_type == 4 is DT_DIR, avoid following symlinks (DT_LNK == 10)
                if ent.d_type == 4 then
                    recurse(full_child, depth + 1)
                elseif ent.d_type == 8 or ent.d_type == 0 then
                    local f = io.open(full_child, "rb")
                    if f then
                        local sz = f:seek("end") or 0
                        f:close()
                        total_bytes = total_bytes + sz
                        file_count = file_count + 1
                    end
                end
            end
        end
        ffi.C.closedir(d)
    end

    recurse(dir_path, 0)
    return total_bytes, file_count
end

local scan_folder = IS_WINDOWS and scan_folder_win32 or scan_folder_posix

--------------------------------------------------------------------------------
-- Delete Failure Tracking
--------------------------------------------------------------------------------
local FILE_ATTRIBUTE_NORMAL = 0x80
local WIN32_SIZE_HIGH_MULTIPLIER = 4294967296 -- 2^32: high DWORD of a size
local ERROR_DIR_NOT_EMPTY = 145
local POSIX_ENOTEMPTY = 39 -- Linux value of ENOTEMPTY
local POSIX_DT_DIR = 4
local POSIX_MAX_DEPTH = 15

-- Readable names for the Win32 errors the cleaner commonly hits.
local WIN32_ERROR_NAMES = {
    [2] = "file not found",
    [3] = "path not found",
    [5] = "access denied",
    [32] = "file is in use by another process",
    [145] = "directory is not empty",
}

-- Returns the last OS error as a numeric code and a readable reason.
-- Call it right after the failing API call, before any other OS call.
local function last_os_error()
    if IS_WINDOWS then
        local code = tonumber(ffi.C.GetLastError())
        local name = WIN32_ERROR_NAMES[code] or "unrecognized error"
        return code, string.format("Windows error %d: %s", code, name)
    end

    local code = ffi.errno()
    return code, ffi.string(ffi.C.strerror(code))
end

-- Creates the counters for one cleanup run of one folder.
local function new_clean_stats(dry_run)
    return {
        dry_run = dry_run,
        freed_bytes = 0,
        deleted_files = 0,
        deleted_dirs = 0,
        failure_count = 0,
        first_failure_path = nil,
        first_failure_reason = nil,
    }
end

-- Counts one item that could not be listed or deleted, keeping the first
-- one so the user sees a concrete example of why items were skipped.
local function record_failure(stats, path, reason)
    stats.failure_count = stats.failure_count + 1
    if stats.first_failure_path == nil then
        stats.first_failure_path = path
        stats.first_failure_reason = reason
    end
end

-- Deletes one file with `delete_file(path)` (or only counts it in a dry
-- run) and updates `stats`. `delete_file` returns true or false, reason.
local function finish_file(stats, path, size_bytes, delete_file)
    if not stats.dry_run then
        local deleted, reason = delete_file(path)
        if not deleted then
            record_failure(stats, path, reason)
            return
        end
    end

    stats.freed_bytes = stats.freed_bytes + size_bytes
    stats.deleted_files = stats.deleted_files + 1
end

-- Removes one directory after its contents were cleaned. A directory that
-- still holds undeletable files is not counted again: `remove_directory`
-- returns false with no reason in that case.
local function finish_directory(stats, path, remove_directory)
    if stats.dry_run then
        return
    end

    local removed, reason = remove_directory(path)
    if removed then
        stats.deleted_dirs = stats.deleted_dirs + 1
    elseif reason then
        record_failure(stats, path, reason)
    end
end

--------------------------------------------------------------------------------
-- Directory Cleaner
--------------------------------------------------------------------------------
-- Returns true when a Win32 find handle is NULL or INVALID_HANDLE_VALUE.
local function is_invalid_handle(handle)
    return handle == nil or handle == ffi.cast("HANDLE", -1)
end

-- Combines the two 32-bit halves of a Win32 file size into one number.
local function win32_file_size(find_data)
    local high = tonumber(find_data.nFileSizeHigh)
    local low = tonumber(find_data.nFileSizeLow)
    return high * WIN32_SIZE_HIGH_MULTIPLIER + low
end

-- Deletes one file. Returns true, or false plus the OS error reason.
local function delete_file_win32(path, attributes)
    local wide_path = to_wide(path)

    -- DeleteFileW refuses read-only files, so clear that attribute first.
    if bit.band(attributes, FILE_ATTRIBUTE_READONLY) ~= 0 then
        ffi.C.SetFileAttributesW(wide_path, FILE_ATTRIBUTE_NORMAL)
    end

    if ffi.C.DeleteFileW(wide_path) ~= 0 then
        return true
    end

    local _, reason = last_os_error()
    return false, reason
end

-- Removes one directory. Returns true, false when it is still not empty,
-- or false plus the OS error reason for any other failure.
local function remove_directory_win32(path)
    if ffi.C.RemoveDirectoryW(to_wide(path)) ~= 0 then
        return true
    end

    local code, reason = last_os_error()
    if code == ERROR_DIR_NOT_EMPTY then
        return false, nil
    end
    return false, reason
end

-- Deletes everything below `dir_path` (the folder itself is kept).
-- Returns freed bytes, deleted files, deleted dirs and the stats record.
local function clean_folder_win32(dir_path, dry_run)
    local stats = new_clean_stats(dry_run)
    local recurse

    -- Cleans one child entry: recurses into directories, deletes files.
    local function clean_entry(path, attributes, size_bytes)
        if bit.band(attributes, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0 then
            report_skipped_reparse(path)
            return
        end

        if bit.band(attributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0 then
            recurse(path)
            finish_directory(stats, path, remove_directory_win32)
            return
        end

        finish_file(stats, path, size_bytes, function(file_path)
            return delete_file_win32(file_path, attributes)
        end)
    end

    recurse = function(current_path)
        if not can_traverse_win32(current_path) then
            return
        end

        local find_data = ffi.new("WIN32_FIND_DATAW")
        local pattern = to_wide(current_path .. "\\*")
        local find_handle = ffi.C.FindFirstFileW(pattern, find_data)
        if is_invalid_handle(find_handle) then
            local _, reason = last_os_error()
            record_failure(stats, current_path, "cannot list: " .. reason)
            return
        end

        repeat
            local name = from_wide(find_data.cFileName)
            if name ~= "." and name ~= ".." then
                clean_entry(
                    current_path .. "\\" .. name,
                    find_data.dwFileAttributes,
                    win32_file_size(find_data)
                )
            end
        until ffi.C.FindNextFileW(find_handle, find_data) == 0

        ffi.C.FindClose(find_handle)
    end

    recurse(dir_path)
    return stats.freed_bytes, stats.deleted_files, stats.deleted_dirs, stats
end

-- Returns the size of `path` in bytes, or 0 when it cannot be opened.
local function posix_file_size(path)
    local file = io.open(path, "rb")
    if not file then
        return 0
    end

    local size = file:seek("end") or 0
    file:close()
    return size
end

-- Deletes one file. Returns true, or false plus the OS error reason.
local function delete_file_posix(path)
    if ffi.C.unlink(path) == 0 then
        return true
    end

    local _, reason = last_os_error()
    return false, reason
end

-- Removes one directory. Returns true, false when it is still not empty,
-- or false plus the OS error reason for any other failure.
local function remove_directory_posix(path)
    if ffi.C.rmdir(path) == 0 then
        return true
    end

    local code, reason = last_os_error()
    if code == POSIX_ENOTEMPTY then
        return false, nil
    end
    return false, reason
end

-- Deletes everything below `dir_path` (the folder itself is kept).
-- Returns freed bytes, deleted files, deleted dirs and the stats record.
local function clean_folder_posix(dir_path, dry_run)
    local stats = new_clean_stats(dry_run)
    local recurse

    -- Cleans one child entry: recurses into directories, deletes the rest.
    -- Symlinks are unlinked, never followed.
    local function clean_entry(path, entry_type, depth)
        if entry_type == POSIX_DT_DIR then
            recurse(path, depth + 1)
            finish_directory(stats, path, remove_directory_posix)
            return
        end

        local size_bytes = posix_file_size(path)
        finish_file(stats, path, size_bytes, delete_file_posix)
    end

    recurse = function(current_path, depth)
        if depth > POSIX_MAX_DEPTH then
            local reason = string.format(
                "nested deeper than %d levels; not cleaned",
                POSIX_MAX_DEPTH
            )
            record_failure(stats, current_path, reason)
            return
        end

        local dir = ffi.C.opendir(current_path)
        if dir == nil then
            local _, reason = last_os_error()
            record_failure(stats, current_path, "cannot list: " .. reason)
            return
        end

        while true do
            local entry = ffi.C.readdir(dir)
            if entry == nil then
                break
            end

            local name = ffi.string(entry.d_name)
            if name ~= "." and name ~= ".." then
                local path = current_path .. "/" .. name
                clean_entry(path, entry.d_type, depth)
            end
        end

        ffi.C.closedir(dir)
    end

    recurse(dir_path, 0)
    return stats.freed_bytes, stats.deleted_files, stats.deleted_dirs, stats
end

local clean_folder = IS_WINDOWS and clean_folder_win32 or clean_folder_posix

--------------------------------------------------------------------------------
-- Empty Windows Recycle Bin via Shell32 FFI
--------------------------------------------------------------------------------
local SHERB_NOCONFIRMATION = 0x1
local SHERB_NOPROGRESSUI = 0x2
local SHERB_NOSOUND = 0x4
local S_OK = 0
-- SHEmptyRecycleBinW returns E_UNEXPECTED when the bin is already empty,
-- which is the normal case here because its folder was just cleaned.
local E_UNEXPECTED = bit.tobit(0x8000FFFF)

-- Empties the Recycle Bin on all drives without any UI.
-- Returns true, or false plus a reason naming the failing call.
local function empty_recycle_bin(dry_run)
    if not IS_WINDOWS or dry_run then
        return true
    end

    local loaded, shell32 = pcall(ffi.load, "shell32")
    if not loaded then
        return false, "cannot load shell32.dll: " .. tostring(shell32)
    end

    -- pcall: declaring the same function twice raises an error.
    pcall(ffi.cdef, [[
        HRESULT SHEmptyRecycleBinW(HWND hwnd, LPCWSTR pszRootPath, DWORD dwFlags);
    ]])

    local flags = bit.bor(
        SHERB_NOCONFIRMATION,
        SHERB_NOPROGRESSUI,
        SHERB_NOSOUND
    )
    local result = shell32.SHEmptyRecycleBinW(nil, nil, flags)
    if result == S_OK or result == E_UNEXPECTED then
        return true
    end

    return false, string.format(
        "SHEmptyRecycleBinW failed with HRESULT 0x%s",
        bit.tohex(result)
    )
end

--------------------------------------------------------------------------------
-- Windows Update Service Control
--------------------------------------------------------------------------------
-- Stopped in this order and restarted in reverse, so the update cache in
-- SoftwareDistribution\Download is not locked while it is cleaned.
local UPDATE_SERVICES = { "wuauserv", "bits" }

-- Returns true when os.execute reports exit status 0. LuaJIT returns the
-- raw status number; Lua 5.2+ semantics return true, "exit", code.
local function command_succeeded(first_result, _, exit_code)
    if type(first_result) == "number" then
        return first_result == 0
    end
    return first_result == true and (exit_code or 0) == 0
end

-- Returns true when `sc query` reports the Windows service as RUNNING.
local function is_service_running(service_name)
    local pipe = io.popen('sc query "' .. service_name .. '" 2>nul')
    if not pipe then
        return false
    end

    local output = pipe:read("*a") or ""
    pipe:close()
    return output:find("RUNNING", 1, true) ~= nil
end

-- Stops the update services that are running. Returns the list of services
-- this call stopped, so only those are restarted afterwards.
local function stop_update_services()
    local stopped_services = {}

    for _, service_name in ipairs(UPDATE_SERVICES) do
        if is_service_running(service_name) then
            local command = 'net stop "' .. service_name .. '" >nul 2>&1'
            if command_succeeded(os.execute(command)) then
                table.insert(stopped_services, service_name)
            else
                io.stderr:write(string.format(
                    "\n[WARNING] Could not stop service '%s' (needs "
                        .. "Administrator). Files it holds open will be "
                        .. "skipped.\n",
                    service_name
                ))
            end
        end
    end

    return stopped_services
end

-- Restarts the given services in reverse order of stopping them.
local function restart_services(stopped_services)
    for index = #stopped_services, 1, -1 do
        local service_name = stopped_services[index]
        local command = 'net start "' .. service_name .. '" >nul 2>&1'
        if not command_succeeded(os.execute(command)) then
            io.stderr:write(string.format(
                "[WARNING] Could not restart service '%s'. Start it from an "
                    .. "Administrator prompt with: net start %s\n",
                service_name,
                service_name
            ))
        end
    end
end

--------------------------------------------------------------------------------
-- Target Directory Configuration
--------------------------------------------------------------------------------
local function get_targets()
    local targets = {}

    if IS_WINDOWS then
        local localappdata = os.getenv("LOCALAPPDATA") or "C:\\Users\\Default\\AppData\\Local"
        local systemroot   = os.getenv("SystemRoot") or "C:\\Windows"

        table.insert(targets, { name = "User Temp Cache", path = localappdata .. "\\Temp" })
        table.insert(targets, { name = "System Temp Cache", path = systemroot .. "\\Temp" })
        table.insert(targets, { name = "Windows Update Cache", path = systemroot .. "\\SoftwareDistribution\\Download", service_stop = true })
        table.insert(targets, { name = "Windows WER Crash Logs", path = localappdata .. "\\Microsoft\\Windows\\WER" })
        table.insert(targets, { name = "Recycle Bin", path = "C:\\$Recycle.Bin", is_recycle_bin = true })
    else
        -- Linux / WSL environment fallback targets
        local home = os.getenv("HOME") or "."
        table.insert(targets, { name = "System Temp", path = "/tmp" })
        table.insert(targets, { name = "User Cache", path = home .. "/.cache" })
        if io.open("/mnt/c", "r") then
            table.insert(targets, { name = "WSL C: Drive Temp", path = "/mnt/c/Windows/Temp" })
        end
    end

    return targets
end

--------------------------------------------------------------------------------
-- Per-Target Cleanup & Reporting
--------------------------------------------------------------------------------
-- Converts a byte count to megabytes rounded down to two decimals.
local function bytes_to_mb(bytes)
    return math.floor((bytes / (1024 * 1024)) * 100) / 100
end

-- Cleans one target folder, stopping its services first when needed.
-- Returns freed bytes, deleted file count and the cleanup stats record.
local function clean_target(target, dry_run)
    local stopped_services = {}
    if target.service_stop and IS_WINDOWS and not dry_run then
        stopped_services = stop_update_services()
    end

    -- pcall so stopped services restart even after an error or Ctrl+C.
    local cleaned, freed_bytes, deleted_files, _, stats =
        pcall(clean_folder, target.path, dry_run)
    restart_services(stopped_services)
    if not cleaned then
        error(freed_bytes, 0)
    end

    if target.is_recycle_bin then
        local emptied, reason = empty_recycle_bin(dry_run)
        if not emptied then
            record_failure(stats, "Recycle Bin", reason)
        end
    end

    return freed_bytes, deleted_files, stats
end

-- Prints the result line for one target, with an example skipped item.
local function print_target_result(freed_bytes, stats)
    local freed_mb = bytes_to_mb(freed_bytes)
    if stats.failure_count == 0 then
        io.write(string.format(
            "%s[OK] Done%s (%s%.2f MB freed%s)\n",
            C.green, C.reset, C.b_white, freed_mb, C.reset
        ))
        return
    end

    io.write(string.format(
        "%s[PARTIAL]%s %s%.2f MB freed%s, %d items skipped\n",
        C.yellow, C.reset, C.b_white, freed_mb, C.reset,
        stats.failure_count
    ))
    io.write(string.format(
        "      %sfirst skipped: %s%s\n      %sreason: %s%s\n",
        C.gray, stats.first_failure_path, C.reset,
        C.gray, stats.first_failure_reason, C.reset
    ))
end

--------------------------------------------------------------------------------
-- Main Cleanup Routine
--------------------------------------------------------------------------------
local function main(args)
    local scan_only = false
    local auto_yes  = false
    local dry_run   = false

    for _, a in ipairs(args) do
        if a == "-h" or a == "--help" then
            print([[clean_c_drive.lua - High-Speed Drive Cleaner (LuaJIT FFI)
Usage:
  clean_c_drive.lua [OPTIONS]

Options:
  -s, --scan        Scan target folders and report sizes only
  -y, --yes         Proceed with cleanup without interactive prompt
  -d, --dry-run     Simulate deletion without modifying files
  --test            Run automated self-tests
  -h, --help        Show this help message
]])
            return
        elseif a == "--test" then
            print(C.b_cyan .. "[TEST] Running clean_c_drive.lua Automated Verification Suite..." .. C.reset)

            -- 1. Test Unicode conversion (round-trip)
            if IS_WINDOWS then
                local orig_str = "C:\\Windows\\Temp\\test_file.tmp"
                local w = to_wide(orig_str)
                assert(w ~= nil, "to_wide should return non-nil")
                local back = from_wide(w)
                assert(back == orig_str, string.format("Unicode conversion failed: expected '%s', got '%s'", orig_str, back))
                print("  [PASS] to_wide and from_wide round-trip conversion")
            end

            -- 2. Test get_targets
            local targets = get_targets()
            assert(type(targets) == "table", "get_targets should return table")
            assert(#targets > 0, "get_targets should discover targets")
            for _, t in ipairs(targets) do
                assert(t.name and t.name ~= "", "Target must have a name")
                assert(t.path and t.path ~= "", "Target must have a path")
            end
            print(string.format("  [PASS] get_targets(): discovered %d valid cleanup targets", #targets))

            -- 3. Test folder scanning on current repository
            local scanned_bytes, scanned_files = scan_folder(".")
            assert(scanned_files > 0, "scan_folder on '.' should discover files")
            assert(scanned_bytes > 0, "scan_folder on '.' should discover positive bytes")
            print(string.format("  [PASS] scan_folder('.'): found %d files (%d bytes)", scanned_files, scanned_bytes))

            -- 4. Test dry-run folder cleaning on temporary test directory
            local tmp_dir = os.getenv("TEMP") or "/tmp"
            local test_folder = tmp_dir .. "\\clean_c_test_" .. tostring(os.time())
            if not IS_WINDOWS then test_folder = tmp_dir .. "/clean_c_test_" .. tostring(os.time()) end

            -- `>nul` is Windows-only: on POSIX it creates a file named "nul".
            local mkdir_command
            if IS_WINDOWS then
                mkdir_command = 'mkdir "' .. test_folder .. '" >nul 2>&1'
            else
                mkdir_command = 'mkdir -p "' .. test_folder .. '"'
            end
            os.execute(mkdir_command)

            local f1 = io.open(test_folder .. (IS_WINDOWS and "\\file1.tmp" or "/file1.tmp"), "w")
            if f1 then f1:write("test content 1"); f1:close() end
            local f2 = io.open(test_folder .. (IS_WINDOWS and "\\file2.tmp" or "/file2.tmp"), "w")
            if f2 then f2:write("test content 2"); f2:close() end

            local freed, del_f = clean_folder(test_folder, true) -- dry_run = true
            assert(del_f == 2, string.format("Dry run should report 2 files, got %d", del_f))
            assert(freed > 0, "Dry run should report positive freed bytes")

            -- Verify files were NOT actually deleted in dry run
            local check_f = io.open(test_folder .. (IS_WINDOWS and "\\file1.tmp" or "/file1.tmp"), "r")
            assert(check_f ~= nil, "File should still exist after dry-run")
            if check_f then check_f:close() end

            -- Clean up real folder
            clean_folder(test_folder, false)
            if IS_WINDOWS then
                os.execute("rmdir \"" .. test_folder .. "\" >nul 2>&1")
            else
                os.execute("rm -rf \"" .. test_folder .. "\" 2>/dev/null")
            end
            print("  [PASS] clean_folder dry-run simulation and safe cleanup")

            -- 5. A file that cannot be deleted is reported, not hidden.
            -- POSIX only, and not as root (root ignores permissions).
            if not IS_WINDOWS and ffi.C.getuid() ~= 0 then
                local locked_root = test_folder .. "_locked"
                local locked_dir = locked_root .. "/readonly"
                os.execute('mkdir -p "' .. locked_dir .. '"')
                local locked_file = io.open(locked_dir .. "/keep.tmp", "w")
                assert(locked_file, "cannot create " .. locked_dir)
                locked_file:write("locked")
                locked_file:close()
                os.execute('chmod 555 "' .. locked_dir .. '"')

                local _, _, _, stats = clean_folder(locked_root, false)

                os.execute('chmod 755 "' .. locked_dir .. '"')
                os.execute('rm -rf "' .. locked_root .. '"')
                assert(
                    stats.failure_count == 1,
                    "expected 1 failure, got " .. stats.failure_count
                )
                assert(
                    stats.first_failure_reason == "Permission denied",
                    "unexpected reason: "
                        .. tostring(stats.first_failure_reason)
                )
                print("  [PASS] undeletable file reported with its reason")
            end

            print(C.b_green .. "[ALL TESTS PASSED SUCCESSFULLY]" .. C.reset)
            return
        elseif a == "-s" or a == "--scan" then
            scan_only = true
        elseif a == "-y" or a == "--yes" then
            auto_yes = true
        elseif a == "-d" or a == "--dry-run" then
            dry_run = true
        else
            -- Never guess: a mistyped --dry-run must not delete for real.
            io.stderr:write(string.format(
                "error: unknown option '%s'\n"
                    .. "Run 'clean_c_drive.lua --help' to see the options.\n",
                a
            ))
            os.exit(2)
        end
    end

    io.write(string.format("%s========================================================%s\n", C.b_cyan, C.reset))
    io.write(string.format("%s  CLEAN C DRIVE - High-Speed Drive Cleaner%s\n", C.b_yellow, C.reset))
    io.write(string.format("%s  * Engine: %s (%s FFI)%s\n", C.green, (jit and jit.version or "LuaJIT"), ffi.os, C.reset))
    io.write(string.format("%s========================================================%s\n", C.b_cyan, C.reset))

    -- 1. Check Administrator Rights
    local admin = is_admin()
    if admin then
        io.write(string.format("%s[OK]%s Running with Administrator privileges.\n\n", C.green, C.reset))
    else
        io.write(string.format("%s[WARNING]%s Not running as Administrator. Some system folders may be protected.\n\n", C.yellow, C.reset))
    end

    -- 2. Scan Targets
    io.write(string.format("%sSCANNING TARGET FOLDERS...%s\n", C.b_cyan, C.reset))
    local targets = get_targets()
    local grand_total_bytes = 0
    local grand_total_files = 0

    local scan_start = os.clock()
    for _, t in ipairs(targets) do
        local bytes, files = scan_folder(t.path)
        t.bytes = bytes
        t.files = files
        grand_total_bytes = grand_total_bytes + bytes
        grand_total_files = grand_total_files + files

        local mb = math.floor((bytes / (1024 * 1024)) * 100) / 100
        if files > 0 then
            io.write(string.format("  %-26s %s%7.2f MB%s (%s%d files%s)\n",
                t.name .. ":", C.b_white, mb, C.reset, C.gray, files, C.reset))
        else
            io.write(string.format("  %-26s %s   0.00 MB%s\n", t.name .. ":", C.gray, C.reset))
        end
    end
    local scan_elapsed = math.floor((os.clock() - scan_start) * 1000)

    local total_mb = math.floor((grand_total_bytes / (1024 * 1024)) * 100) / 100
    local total_gb = math.floor((grand_total_bytes / (1024 * 1024 * 1024)) * 100) / 100

    io.write(string.format("%s--------------------------------------------------------%s\n", C.b_cyan, C.reset))
    io.write(string.format("%sPotential space to recover: %s%.2f MB (%.2f GB)%s across %d files [%d ms]\n",
        C.b_cyan, C.b_yellow, total_mb, total_gb, C.b_cyan, grand_total_files, scan_elapsed))
    io.write(string.format("%s========================================================%s\n\n", C.b_cyan, C.reset))

    if scan_only then
        return
    end

    -- On Linux/WSL the targets are shared folders such as /tmp, where
    -- deleting breaks running programs, so require an explicit --yes.
    if not IS_WINDOWS and not auto_yes and not dry_run then
        io.write(string.format(
            "%s[SCAN ONLY]%s Linux/WSL cleanup deletes from /tmp and "
                .. "~/.cache, which can break running programs.\n"
                .. "Re-run with --dry-run to preview or --yes to delete.\n",
            C.yellow, C.reset
        ))
        return
    end

    if grand_total_files == 0 and grand_total_bytes == 0 then
        io.write(string.format("%s[OK] Drive already clean! No temporary files found.%s\n", C.b_green, C.reset))
        return
    end

    -- 3. Confirm Prompt (unless --yes)
    if not auto_yes then
        io.write(string.format("%sPress [ENTER] to clean these folders, or [Ctrl+C] to cancel...%s", C.b_yellow, C.reset))
        io.flush()
        local resp = io.read("*line")
        if not resp then return end
        io.write("\n")
    end

    -- 4. Clean Folders
    local clean_freed_bytes = 0
    local clean_deleted_files = 0
    local clean_failures = 0

    for idx, t in ipairs(targets) do
        if t.files > 0 then
            io.write(string.format("[%d/%d] Cleaning %s... ", idx, #targets, t.name))
            io.flush()

            local freed, del_f, stats = clean_target(t, dry_run)
            clean_freed_bytes = clean_freed_bytes + freed
            clean_deleted_files = clean_deleted_files + del_f
            clean_failures = clean_failures + stats.failure_count
            print_target_result(freed, stats)
        end
    end

    local freed_mb = bytes_to_mb(clean_freed_bytes)
    local freed_gb = math.floor((clean_freed_bytes / (1024 * 1024 * 1024)) * 100) / 100

    io.write(string.format("\n%s========================================================%s\n", C.b_green, C.reset))
    io.write(string.format(
        "%sCLEANUP FINISHED! Freed ~%.2f MB (%.2f GB) across %d files.%s\n",
        C.b_green, freed_mb, freed_gb, clean_deleted_files, C.reset
    ))
    if clean_failures > 0 then
        io.write(string.format(
            "%s[WARNING]%s %d items could not be deleted (in use or "
                .. "access denied).\n"
                .. "Close the programs using them or run as Administrator, "
                .. "then re-run.\n",
            C.yellow, C.reset, clean_failures
        ))
    end
    io.write(string.format("%s========================================================%s\n", C.b_green, C.reset))
end

main({...})
