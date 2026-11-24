#requires -Version 7.7
#requires -PSEdition Core
<#
.SYNOPSIS
Launch the Default or DatabaseManagement profile from the existing VS Code pins.
.DESCRIPTION
Default leaves taskbar grouping and Jump Lists to VS Code. DatabaseManagement
groups windows by their profile title and publishes a snapshot of VS Code's shared
local history. Windows controls whether recent items appear in Jump Lists.
.EXAMPLE
pwsh -NoProfile -File .\Start-VSCodeProfileTaskbar.ps1 -ProfileName DatabaseManagement -Check
Check the executable, icon, recent history and window matching without changing the taskbar.
.NOTES
Requires PowerShell 7.7 or later on Windows. The existing pinned shortcuts
can keep their current arguments. Jump List links use the same PowerShell installation.
If you customize window.title, use -WindowTitlePattern with a wildcard that matches
only DatabaseManagement. Grouping cannot happen until VS Code shows that profile's title.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Default', 'DatabaseManagement')]
    [string]$ProfileName,
    [string]$CodePath = (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
    [string]$IconPath = (Join-Path $env:USERPROFILE 'Pictures\vscode-alt.ico'),
    [string]$AppUserModelId,
    [string]$WindowTitlePattern,
    [ValidateRange(1, 120)][int]$WaitSeconds = 15,
    [switch]$ForceNewWindow,
    [string]$FileUri,
    [string]$FolderUri,
    [switch]$Check,

    # Legacy shortcut arguments. No polling or stabilization delay is needed.
    [string]$ShortcutName,
    [int]$RestampSeconds,
    [int]$StableMilliseconds
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This launcher requires Windows.' }

function Initialize-TaskbarInterop {
    if ('VSCodeProfileLauncher.Taskbar' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace VSCodeProfileLauncher
{
    public sealed class Taskbar
    {
        public enum GroupResult { NewWindow, ReusedWindow, TimedOut, Interrupted }

        private const uint Foreground = 0x0003, Show = 0x8002, NameChange = 0x800C;
        private const int AccessDenied = unchecked((int)0x80070005);
        private const int NoInterface = unchecked((int)0x80004002);
        private static readonly PropertyKey AppId = new PropertyKey("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3", 5);
        private static readonly PropertyKey Title = new PropertyKey("F29F85E0-4FF9-1068-AB91-08002B27B3D9", 2);
        private readonly string codePath;
        private readonly Predicate<string> matchesTitle;

        public Taskbar(string codePath, Predicate<string> matchesTitle)
        {
            this.codePath = codePath;
            this.matchesTitle = matchesTitle;
        }

        public IntPtr[] MatchingWindows()
        {
            var matches = new List<IntPtr>();
            // Do not call managed matching code from the native enumeration callback.
            var windows = new List<IntPtr>();
            if (!EnumWindows((window, unused) => { windows.Add(window); return true; }, IntPtr.Zero))
                throw new Win32Exception();
            foreach (var window in windows)
                if (Match(window) != 0) matches.Add(window);
            return matches.ToArray();
        }

        public GroupResult GroupWhenReady(string id, ProcessStartInfo start, int timeoutMs, bool mayReuse)
        {
            var before = new HashSet<IntPtr>();
            var candidates = new Queue<(IntPtr Window, bool Focused)>();
            WinEvent callback = (hook, kind, window, obj, child, thread, time) =>
            {
                if (window != IntPtr.Zero && obj == 0 && child == 0)
                    candidates.Enqueue((window, kind == Foreground));
            };
            var hooks = new List<IntPtr>();
            try
            {
                void Listen(uint kind)
                {
                    // Out-of-context: no code is loaded into VS Code or any other process.
                    var hook = SetWinEventHook(kind, kind, IntPtr.Zero, callback, 0, 0, 0);
                    if (hook == IntPtr.Zero) throw new InvalidOperationException("Could not register a window notification.");
                    hooks.Add(hook);
                }
                try
                {
                    if (start != null) before.UnionWith(MatchingWindows());
                    Listen(Show);
                    Listen(NameChange);
                    if (mayReuse) Listen(Foreground);
                }
                finally
                {
                    // For a running instance, arm notifications before requesting a window.
                    // Launch even if the notification API fails.
                    if (start != null) Process.Start(start).Dispose();
                }

                // Cover a title that was already ready before the hooks were installed.
                var clock = Stopwatch.StartNew();
                bool foundNew = false;
                foreach (var window in MatchingWindows())
                    if (Stamp(window, id) && !before.Contains(window)) foundNew = true;
                if (foundNew) return GroupResult.NewWindow;

                while (clock.ElapsedMilliseconds < timeoutMs)
                {
                    // PeekMessage delivers WinEvents even when it returns no posted message.
                    bool hadMessage = PeekMessage(out Message message, IntPtr.Zero, 0, 0, 1);
                    if (hadMessage)
                    {
                        if (message.Id == 0x0012) // WM_QUIT: let the host handle it.
                        {
                            PostQuitMessage((int)message.WParam);
                            return GroupResult.Interrupted;
                        }
                        DispatchMessage(ref message);
                    }

                    while (candidates.Count != 0 && clock.ElapsedMilliseconds < timeoutMs)
                    {
                        var candidate = candidates.Dequeue();
                        if (!Stamp(candidate.Window, id)) continue;
                        if (!before.Contains(candidate.Window)) return GroupResult.NewWindow;
                        if (candidate.Focused) return GroupResult.ReusedWindow;
                    }

                    if (hadMessage) continue;
                    uint remaining = (uint)Math.Max(0, timeoutMs - clock.ElapsedMilliseconds);
                    const uint allInput = 0x04ff, inputAvailable = 4;
                    uint wait = MsgWaitForMultipleObjectsEx(0, IntPtr.Zero, remaining, allInput, inputAvailable);
                    if (wait == 258) break; // WAIT_TIMEOUT
                    if (wait != 0) throw new Win32Exception();
                }
                return GroupResult.TimedOut;
            }
            finally
            {
                foreach (var hook in hooks) UnhookWinEvent(hook);
                GC.KeepAlive(callback);
            }
        }

        private uint Match(IntPtr window)
        {
            if (!IsWindowVisible(window) || GetAncestor(window, 2) != window) return 0; // GA_ROOT
            var text = new StringBuilder(64);
            if (GetClassName(window, text, text.Capacity) == 0 ||
                !text.ToString().StartsWith("Chrome_WidgetWin_", StringComparison.Ordinal)) return 0;
            var title = new StringBuilder(GetWindowTextLength(window) + 32);
            if (GetWindowText(window, title, title.Capacity) == 0 || !matchesTitle(title.ToString())) return 0;
            return GetWindowThreadProcessId(window, out uint pid) != 0 && IsCodeProcess(pid) ? pid : 0;
        }

        private bool IsCodeProcess(uint pid)
        {
            var handle = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
            if (handle == IntPtr.Zero) return false;
            try
            {
                var name = new StringBuilder(32768);
                int length = name.Capacity;
                if (!QueryFullProcessImageName(handle, 0, name, ref length)) return false;
                string path = name.ToString();
                if (StringComparer.OrdinalIgnoreCase.Equals(path, codePath)) return true;

                string directory = Path.GetDirectoryName(path);
                return StringComparer.OrdinalIgnoreCase.Equals(Path.GetFileName(path), "Code.exe")
                    && StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(directory), Path.GetDirectoryName(codePath))
                    && System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(directory), @"\A[0-9a-fA-F]{10}\z");
            }
            finally { CloseHandle(handle); }
        }

        private bool Stamp(IntPtr window, string id)
        {
            uint owner = Match(window);
            if (owner == 0 || GetWindowThreadProcessId(window, out uint pid) == 0 || pid != owner) return false;
            Guid iid = typeof(IPropertyStore).GUID;
            int status = SHGetPropertyStoreForWindow(window, ref iid, out IPropertyStore store);
            if (status < 0 && !IsWindow(window)) return false;
            Marshal.ThrowExceptionForHR(status);
            try
            {
                var key = AppId;
                store.GetValue(ref key, out PropVariant current);
                try
                {
                    if (current.Type == 31 && Marshal.PtrToStringUni(current.Value) == id) return true;
                }
                finally { PropVariantClear(ref current); }
                SetText(store, key, id); // The window property store applies changes immediately.
                return true;
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static string ReadHistory(string path)
        {
            IntPtr db = IntPtr.Zero, statement = IntPtr.Zero;
            void Check(int status)
            {
                if (status != 0) throw new InvalidOperationException("Cannot read VS Code history (SQLite " + status + "): " + path);
            }
            try
            {
                Check(sqlite3_open_v2(path, out db, 1, IntPtr.Zero)); // SQLITE_OPEN_READONLY
                const string sql = "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'";
                Check(sqlite3_prepare_v2(db, sql, -1, out statement, IntPtr.Zero));
                int status = sqlite3_step(statement);
                if (status == 101) return null; // No row.
                if (status != 100) Check(status);
                return Marshal.PtrToStringUni(sqlite3_column_text16(statement, 0));
            }
            finally
            {
                if (statement != IntPtr.Zero) sqlite3_finalize(statement);
                if (db != IntPtr.Zero) sqlite3_close(db);
            }
        }

        public static int Publish(string id, string host, string icon, string startArgs, string[] arguments, string[] titles)
        {
            var list = (ICustomDestinationList)new DestinationList();
            IObjectArray removed = null;
            IObjectCollection tasks = null, items = null;
            bool pending = false;
            try
            {
                list.SetAppID(id);
                Guid iid = typeof(IObjectArray).GUID;
                list.BeginList(out uint slots, ref iid, out removed);
                pending = true;

                tasks = (IObjectCollection)new ObjectCollection();
                AddLink(tasks, host, icon, startArgs, "New Window");
                list.AddUserTasks((IObjectArray)tasks);

                var excluded = RemovedArguments(removed);
                items = (IObjectCollection)new ObjectCollection();
                int count = 0;
                for (int i = 0; i < arguments.Length && count < Math.Min(slots, 10u); i++)
                {
                    if (excluded.Contains(arguments[i])) continue;
                    AddLink(items, host, icon, arguments[i], titles[i]);
                    count++;
                }
                if (count > 0)
                {
                    int status = list.AppendCategory("Recent", (IObjectArray)items);
                    if (status == AccessDenied) count = -1; // Windows permits tasks, not recents.
                    else Marshal.ThrowExceptionForHR(status);
                }
                list.CommitList();
                pending = false;
                return count;
            }
            finally
            {
                if (pending) list.AbortList();
                if (items != null) Marshal.ReleaseComObject(items);
                if (tasks != null) Marshal.ReleaseComObject(tasks);
                if (removed != null) Marshal.ReleaseComObject(removed);
                Marshal.ReleaseComObject(list);
            }
        }

        private static HashSet<string> RemovedArguments(IObjectArray removed)
        {
            var excluded = new HashSet<string>(StringComparer.Ordinal);
            removed.GetCount(out uint count);
            for (uint i = 0; i < count; i++)
            {
                Guid iid = typeof(IShellLink).GUID;
                int status = removed.GetAt(i, ref iid, out IShellLink link);
                if (status == NoInterface) continue;
                Marshal.ThrowExceptionForHR(status);
                try
                {
                    var args = new StringBuilder(32768);
                    link.GetArguments(args, args.Capacity);
                    excluded.Add(args.ToString());
                }
                finally { Marshal.ReleaseComObject(link); }
            }
            return excluded;
        }

        private static void AddLink(IObjectCollection items, string host, string icon, string args, string title)
        {
            var link = (IShellLink)new ShellLink();
            try
            {
                link.SetPath(host);
                link.SetArguments(args);
                link.SetIconLocation(icon, 0);
                link.SetShowCmd(7);
                var properties = (IPropertyStore)link;
                SetText(properties, Title, title);
                properties.Commit();
                items.AddObject(link);
            }
            finally { Marshal.ReleaseComObject(link); }
        }

        private static void SetText(IPropertyStore store, PropertyKey key, string text)
        {
            var value = new PropVariant { Type = 31, Value = Marshal.StringToCoTaskMemUni(text) }; // VT_LPWSTR
            try { store.SetValue(ref key, ref value); }
            finally { PropVariantClear(ref value); }
        }

        private delegate bool EnumCallback(IntPtr window, IntPtr parameter);
        private delegate void WinEvent(IntPtr hook, uint kind, IntPtr window, int obj, int child, uint thread, uint time);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EnumWindows(EnumCallback callback, IntPtr parameter);
        [DllImport("user32.dll")]
        private static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr window, StringBuilder title, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLength(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr window, StringBuilder name, int size);
        [DllImport("user32.dll")]
        private static extern IntPtr SetWinEventHook(uint first, uint last, IntPtr module, WinEvent callback, uint process, uint thread, uint flags);
        [DllImport("user32.dll")]
        private static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint MsgWaitForMultipleObjectsEx(uint count, IntPtr handles, uint timeout, uint mask, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool PeekMessage(out Message msg, IntPtr window, uint first, uint last, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr DispatchMessage(ref Message msg);
        [DllImport("user32.dll")]
        private static extern void PostQuitMessage(int code);
        [DllImport("kernel32.dll")]
        private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int length);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("shell32.dll")]
        private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, out IPropertyStore store);
        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr db, int flags, IntPtr vfs);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPStr)] string sql, int count, out IntPtr statement, IntPtr tail);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text16(IntPtr statement, int column);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr db);

        [StructLayout(LayoutKind.Sequential)]
        private struct Message
        {
            public IntPtr Window;
            public uint Id;
            public UIntPtr WParam;
            public IntPtr LParam;
            public uint Time;
            public int X, Y;
            public uint Reserved;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PropertyKey
        {
            public Guid Format;
            public uint Id;
            public PropertyKey(string format, uint id) { Format = new Guid(format); Id = id; }
        }

        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropVariant
        {
            [FieldOffset(0)] public ushort Type;
            [FieldOffset(8)] public IntPtr Value;
        }

        // COM methods must stay in their vtable order, including unused slots.
        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            void GetCount(out uint count);
            void GetAt(uint index, out PropertyKey key);
            void GetValue(ref PropertyKey key, out PropVariant value);
            void SetValue(ref PropertyKey key, ref PropVariant value);
            void Commit();
        }

        [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
        private class ShellLink {}

        [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLink
        {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int length, IntPtr data, uint flags);
            void GetIDList(out IntPtr pidl);
            void SetIDList(IntPtr pidl);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int length);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int length);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
            void GetHotkey(out short hotkey);
            void SetHotkey(short hotkey);
            void GetShowCmd(out int showCommand);
            void SetShowCmd(int showCommand);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, out int index);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
            void Resolve(IntPtr window, uint flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
        }

        [ComImport, Guid("77f10cf0-3db5-4966-b520-b7c54fd35ed6")]
        private class DestinationList {}

        [ComImport, Guid("6332debf-87b5-4670-90c0-5e57b408a49e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface ICustomDestinationList
        {
            void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string id);
            void BeginList(out uint slots, ref Guid iid, out IObjectArray removed);
            [PreserveSig] int AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string name, IObjectArray items);
            void AppendKnownCategory(int category);
            void AddUserTasks(IObjectArray items);
            void CommitList();
            void GetRemovedDestinations(ref Guid iid, out IObjectArray removed);
            void DeleteList([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int AbortList();
        }

        [ComImport, Guid("92CA9DCD-5622-4bba-A805-5E9F541BD8C9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IObjectArray
        {
            void GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, ref Guid iid, out IShellLink item);
        }

        [ComImport, Guid("2d3468c1-36a7-43b6-ac24-d3f02fd9607a")]
        private class ObjectCollection {}

        [ComImport, Guid("5632b1a4-e38a-400a-928a-d4cd63230295"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IObjectCollection
        {
            void GetCount(out uint count);
            void GetAt(uint index, ref Guid iid, out IShellLink item);
            void AddObject([MarshalAs(UnmanagedType.IUnknown)] object item);
            void AddFromArray(IObjectArray source);
            void RemoveObjectAt(uint index);
            void Clear();
        }
    }
}
'@
}

function Test-LocalFileUri($Value) {
    $Value -is [string] -and $Value -match '\Afile:///[a-z](?::|%3a)/[^"\s\\?#\x00-\x1f\x7f]*\z'
}

function Get-RecentDestination {
    $json = $null
    foreach ($db in "$env:USERPROFILE\.vscode-shared\sharedStorage\state.vscdb", "$env:APPDATA\Code\User\globalStorage\state.vscdb") {
        if (Test-Path -LiteralPath $db -PathType Leaf) {
            $json = [VSCodeProfileLauncher.Taskbar]::ReadHistory($db)
            if ($null -ne $json) { break }
        }
    }
    if ($null -eq $json) {
        Write-Verbose 'No VS Code recent history was found.'
        return
    }

    $history = ConvertFrom-Json -InputObject $json -AsHashtable -DateKind String
    if ($history -isnot [Collections.IDictionary] -or $history['entries'] -isnot [array]) {
        throw 'VS Code history has an unexpected format.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $history['entries']) {
        if ($entry -isnot [Collections.IDictionary]) { continue }
        $flag = '-FileUri'
        if ($entry['folderUri']) {
            $uri = $entry['folderUri']
            $flag = '-FolderUri'
        }
        elseif ($entry['workspace'] -is [Collections.IDictionary]) { $uri = $entry['workspace']['configPath'] }
        else { $uri = $entry['fileUri'] }

        if (-not (Test-LocalFileUri $uri) -or -not $seen.Add($uri)) { continue }
        $trimmed = $uri.TrimEnd('/')
        $title = [uri]::UnescapeDataString($trimmed.Substring($trimmed.LastIndexOf('/') + 1))
        if (-not $title -or $title -eq 'agent-sessions.code-workspace' -or $title -match '[\x00-\x1f]') { continue }
        [pscustomobject]@{ Arguments = " $flag $uri"; Title = $title.Substring(0, [Math]::Min(255, $title.Length)) }
    }
}

function Get-LauncherHost {
    $launcher = Join-Path $PSHOME 'pwsh.exe'
    if ($PSHOME -like '*\WindowsApps\Microsoft.PowerShell_*__8wekyb3d8bbwe') {
        # The package alias stays valid across Store updates and avoids the shared pwsh.exe alias.
        $launcher = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe'
    }
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "PowerShell executable for Jump List links was not found: $launcher"
    }
    $launcher
}

function Join-WindowsArguments([string[]]$Values) {
    # IShellLink stores a Windows command line, not an argv array.
    $quoted = foreach ($value in $Values) {
        if ($value -and $value -notmatch '[\s"]') { $value }
        else { '"' + (($value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }
    $quoted -join ' '
}

function Publish-DatabaseJumpList {
    $icon = if (Test-Path -LiteralPath $IconPath -PathType Leaf) { $IconPath } else { $CodePath }
    $linkArgs = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', $PSCommandPath,
        '-ProfileName', 'DatabaseManagement', '-CodePath', $CodePath, '-IconPath', $IconPath, '-ForceNewWindow')
    if ($WindowTitlePattern) { $linkArgs += @('-WindowTitlePattern', $WindowTitlePattern) }
    $command = Join-WindowsArguments $linkArgs
    $recents = @(Get-RecentDestination)
    $arguments = @(foreach ($recent in $recents) { $command + $recent.Arguments })
    $titles = @(foreach ($recent in $recents) { $recent.Title })
    $count = [VSCodeProfileLauncher.Taskbar]::Publish($appId, (Get-LauncherHost), $icon, $command, $arguments, $titles)
    if ($count -lt 0) { Write-Warning 'Windows privacy settings or policy blocked recent items in Jump Lists.' }
    else { Write-Verbose "Published $count DatabaseManagement Jump List destinations." }
}

$isDefault = $ProfileName -eq 'Default'
$ProfileName = if ($isDefault) { 'Default' } else { 'DatabaseManagement' }
$appId = if ($isDefault) { 'Microsoft.VisualStudioCode' } else { 'VSCode.Profile.DatabaseManagement' }
if ($AppUserModelId -and $AppUserModelId -cne $appId) {
    throw "Expected AppUserModelID '$appId' for '$ProfileName', got '$AppUserModelId'."
}
if ($FileUri -and $FolderUri) { throw 'Specify either -FileUri or -FolderUri, not both.' }
$destination = $FileUri + $FolderUri
if ($destination -and -not (Test-LocalFileUri $destination)) { throw 'Expected a local drive file URI.' }
$code = Get-Item -LiteralPath $CodePath
if ($code -isnot [IO.FileInfo] -or $code.Extension -ne '.exe') { throw "Not an executable file: $CodePath" }
$CodePath = $code.FullName

$start = [Diagnostics.ProcessStartInfo]::new($CodePath)
$start.WorkingDirectory = $code.DirectoryName
$start.ArgumentList.Add('--profile')
$start.ArgumentList.Add($ProfileName)
if ($ForceNewWindow) { $start.ArgumentList.Add('--new-window') }
if ($destination) {
    $start.ArgumentList.Add($(if ($FileUri) { '--file-uri' } else { '--folder-uri' }))
    $start.ArgumentList.Add($destination)
}

if ($isDefault) {
    if ($Check) { Write-Output "Default launcher check passed on PowerShell $($PSVersionTable.PSVersion)." }
    else { [Diagnostics.Process]::Start($start).Dispose() }
    return
}

if ($WindowTitlePattern) {
    $pattern = [WildcardPattern]::new($WindowTitlePattern, [WildcardOptions]::IgnoreCase)
    $titleMatches = [Predicate[string]]{ param($title) $pattern.IsMatch($title) }
}
else {
    $titleMatches = [Predicate[string]]{
        param($title)
        $title -eq 'DatabaseManagement - Visual Studio Code' -or
            $title.EndsWith(' - DatabaseManagement - Visual Studio Code', [StringComparison]::OrdinalIgnoreCase)
    }
}

if ($Check) {
    Initialize-TaskbarInterop
    $recentCount = @(Get-RecentDestination).Count
    if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) { throw "Shortcut icon not found: $IconPath" }
    Write-Verbose "Jump List host: $(Get-LauncherHost)"
    $taskbar = [VSCodeProfileLauncher.Taskbar]::new($CodePath, $titleMatches)
    Write-Output "Launcher check passed on PowerShell $($PSVersionTable.PSVersion). $recentCount local recent entries; $($taskbar.MatchingWindows().Length) matching windows."
    $setting = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackDocs' -ErrorAction SilentlyContinue
    if ($null -ne $setting -and $setting -eq 0) {
        Write-Warning 'Windows recent items are off. See Settings > Personalization > Start.'
    }
    return
}

$launchClock = [Diagnostics.Stopwatch]::StartNew()
$deferredLaunch = $null
if (Get-Process -Name $code.BaseName -ErrorAction SilentlyContinue | Select-Object -First 1) {
    $deferredLaunch = $start
}
else { [Diagnostics.Process]::Start($start).Dispose() }

try {
    Initialize-TaskbarInterop
}
catch {
    if ($deferredLaunch) { [Diagnostics.Process]::Start($deferredLaunch).Dispose() }
    Write-Warning "VS Code was launched, but the taskbar helper could not load: $($_.Exception.Message)"
    return
}

try {
    if ($deferredLaunch) { $launchClock.Restart() }
    $taskbar = [VSCodeProfileLauncher.Taskbar]::new($CodePath, $titleMatches)
    $remainingMs = [int][Math]::Max(0, $WaitSeconds * 1000 - $launchClock.ElapsedMilliseconds)
    $result = $taskbar.GroupWhenReady($appId, $deferredLaunch, $remainingMs, [bool]$destination)
    if ($result -eq 'TimedOut') {
        Write-Warning 'No newly opened or reused DatabaseManagement window matched. Check the title or pass -WindowTitlePattern.'
    }
    elseif ($result -eq 'Interrupted') { return }
    else { Write-Verbose "${result}: $($launchClock.ElapsedMilliseconds) ms after launching VS Code." }
}
catch {
    Write-Warning "Could not group the DatabaseManagement window: $($_.Exception.Message)"
}

try { Publish-DatabaseJumpList }
catch { Write-Warning "Could not update the DatabaseManagement Jump List: $($_.Exception.Message)" }
