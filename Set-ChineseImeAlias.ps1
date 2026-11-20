#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Current', 'Select')]
    [string]$Mode = 'Interactive',

    [string]$Alias,

    # For non-interactive Select mode: examples "1,3", "1-4", or "A".
    [string]$Selection,

    [switch]$NoConfirm,
    [switch]$DryRun,

    # 从备份 JSON 恢复注册表 Description 值（指定备份文件路径）
    [string]$Restore,

    # 交互式列出脚本目录 backup 文件夹中的备份，由用户选择要恢复的备份
    [switch]$RestoreMenu,

    # 仅切换当前控制台窗口字体为新宋体后退出（供 bat 启动器在显示菜单前调用）
    [switch]$FixConsoleFontOnly,

    # 启动器菜单（供 bat 双击调用）：显示操作模式 + DryRun 选择，
    # 通过退出码返回：0=退出，11=修改+DryRun，12=修改+运行，21=恢复+DryRun，22=恢复+运行
    [switch]$LauncherMenu
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TipRootPath = 'SOFTWARE\Microsoft\CTF\TIP'
$script:DefaultAlias = -join @(
    [char]0x641C, [char]0x72D7, [char]0x62FC, [char]0x97F3,
    [char]0x8F93, [char]0x5165, [char]0x6CD5
)

# 备份目录固定为脚本所在文件夹下的 backup
$script:BackupDir = Join-Path $PSScriptRoot 'backup'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Use-CjkConsoleFont {
    # 旧版控制台（conhost）的输出区域不做字体回退：字体不含中文字形时中文显示为 ?。
    # 常见于系统区域为英文的机器（默认 Consolas）。这里把当前控制台窗口的字体
    # 切换为系统自带的新宋体（NSimSun），仅影响当前窗口。Windows Terminal /
    # VS Code 终端自带字体回退，无需处理。
    if ($env:WT_SESSION -or $env:TERM_PROGRAM) {
        return
    }
    if ('ImeAliasTool.ConsoleFont' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ImeAliasTool
{
    public static class ConsoleFont
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct COORD { public short X; public short Y; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CONSOLE_FONT_INFOEX
        {
            public uint cbSize;
            public uint nFont;
            public COORD dwFontSize;
            public int FontFamily;
            public int FontWeight;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string FaceName;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool GetCurrentConsoleFontEx(
            IntPtr hConsoleOutput, bool bMaximumWindow,
            ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool SetCurrentConsoleFontEx(
            IntPtr hConsoleOutput, bool bMaximumWindow,
            ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);

        public static bool SetFace(string faceName)
        {
            IntPtr handle = GetStdHandle(-11); // STD_OUTPUT_HANDLE
            if (handle == IntPtr.Zero) return false;

            CONSOLE_FONT_INFOEX info = new CONSOLE_FONT_INFOEX();
            info.cbSize = (uint)Marshal.SizeOf(typeof(CONSOLE_FONT_INFOEX));
            if (!GetCurrentConsoleFontEx(handle, false, ref info)) return false;
            if (string.Equals(info.FaceName, faceName,
                StringComparison.OrdinalIgnoreCase)) return true;

            info.FaceName = faceName;
            return SetCurrentConsoleFontEx(handle, false, ref info);
        }
    }
}
'@

    try {
        [void][ImeAliasTool.ConsoleFont]::SetFace('NSimSun')
    }
    catch {
        # 字体切换失败不影响脚本功能
    }
}

function Show-LauncherMenu {
    # 启动器菜单放在 ps1 而不是 bat 中：cmd 在 chcp 65001 下解析含多字节字符的
    # 批处理行存在字节偏移 bug（部分旧版 Windows 会把一行截断执行后半截），
    # bat 文件必须保持纯 ASCII，中文界面全部由 PowerShell 输出
    Write-Host ''
    Write-Host '=========================================='
    Write-Host '  Windows 中文输入法 Description 修改工具'
    Write-Host '=========================================='
    Write-Host '  1. 修改输入法 Description（默认）'
    Write-Host '  2. 从备份恢复（列出 backup 目录中的备份）'
    Write-Host '  Q. 退出'
    Write-Host ''

    $op = ''
    while ($true) {
        $opInput = Read-Host '请选择 [1/2/Q]（直接回车=1）'
        if ($null -eq $opInput) {
            # stdin 被重定向且已读完（EOF）时 Read-Host 返回 $null，按退出处理
            return 0
        }
        $op = $opInput.Trim()
        if ($op -eq '') {
            $op = '1'
        }
        if ($op -match '^(?i:q|quit)$') {
            return 0
        }
        if ($op -eq '1' -or $op -eq '2') {
            break
        }
        Write-Host ('无效的选择：{0}' -f $op)
    }

    Write-Host ''
    $dryInput = Read-Host '是否以 DryRun 模拟运行（不写入注册表）？[Y/N]（直接回车=N）'
    if ($null -eq $dryInput) {
        $dryInput = ''
    }
    $dryCode = 2
    if ($dryInput.Trim() -match '^(?i:y|yes)$') {
        $dryCode = 1
    }
    return ([int]$op) * 10 + $dryCode
}

function Initialize-TsfInterop {
    if ('ImeAliasTool.TsfProfiles' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ImeAliasTool
{
    [StructLayout(LayoutKind.Sequential)]
    public struct TF_INPUTPROCESSORPROFILE
    {
        public uint dwProfileType;
        public ushort langid;
        public Guid clsid;
        public Guid guidProfile;
        public Guid catid;
        public IntPtr hklSubstitute;
        public uint dwCaps;
        public IntPtr hkl;
        public uint dwFlags;
    }

    [ComImport]
    [Guid("71C6E74C-0F28-11D8-A82A-00065B84435C")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ITfInputProcessorProfileMgr
    {
        [PreserveSig]
        int ActivateProfile(uint profileType, ushort langId, ref Guid clsid,
            ref Guid profile, IntPtr hkl, uint flags);

        [PreserveSig]
        int DeactivateProfile(uint profileType, ushort langId, ref Guid clsid,
            ref Guid profile, IntPtr hkl, uint flags);

        [PreserveSig]
        int GetProfile(uint profileType, ushort langId, ref Guid clsid,
            ref Guid profile, IntPtr hkl, out TF_INPUTPROCESSORPROFILE result);

        [PreserveSig]
        int EnumProfiles(ushort langId, out IntPtr enumerator);

        [PreserveSig]
        int ReleaseInputProcessor(ref Guid clsid, uint flags);

        [PreserveSig]
        int RegisterProfile(ref Guid clsid, ushort langId, ref Guid profile,
            [MarshalAs(UnmanagedType.LPWStr)] string description, uint descriptionLength,
            [MarshalAs(UnmanagedType.LPWStr)] string iconFile, uint iconFileLength,
            uint iconIndex, IntPtr substituteHkl, uint preferredLayout,
            [MarshalAs(UnmanagedType.Bool)] bool enabledByDefault, uint flags);

        [PreserveSig]
        int UnregisterProfile(ref Guid clsid, ushort langId, ref Guid profile, uint flags);

        [PreserveSig]
        int GetActiveProfile(ref Guid category, out TF_INPUTPROCESSORPROFILE result);
    }

    public static class TsfProfiles
    {
        private static readonly Guid InputProcessorProfilesClsid =
            new Guid("33C53A50-F456-4884-B049-85FD643ECFED");

        private static readonly Guid KeyboardTipCategory =
            new Guid("34745C63-B2F0-4784-8B67-5E12C8701A31");

        public static TF_INPUTPROCESSORPROFILE GetActiveProfile()
        {
            Type type = Type.GetTypeFromCLSID(InputProcessorProfilesClsid, true);
            object instance = Activator.CreateInstance(type);
            try
            {
                ITfInputProcessorProfileMgr manager =
                    (ITfInputProcessorProfileMgr)instance;
                Guid category = KeyboardTipCategory;
                TF_INPUTPROCESSORPROFILE profile;
                int hr = manager.GetActiveProfile(ref category, out profile);
                if (hr == 1)
                    throw new InvalidOperationException("未找到当前激活的键盘 TSF Profile。");
                if (hr < 0)
                    Marshal.ThrowExceptionForHR(hr);
                return profile;
            }
            finally
            {
                if (instance != null && Marshal.IsComObject(instance))
                    Marshal.FinalReleaseComObject(instance);
            }
        }
    }
}
'@
}

function Get-RegistryViews {
    if ([Environment]::Is64BitOperatingSystem) {
        return @(
            [Microsoft.Win32.RegistryView]::Registry64,
            [Microsoft.Win32.RegistryView]::Registry32
        )
    }

    return @([Microsoft.Win32.RegistryView]::Registry32)
}

function Format-Guid([Guid]$Value) {
    return $Value.ToString('B').ToUpperInvariant()
}

function New-ProfileIdentity([Guid]$Clsid, [UInt16]$LangId, [Guid]$ProfileGuid) {
    return '{0}|{1:X4}|{2}' -f (Format-Guid $Clsid), $LangId, (Format-Guid $ProfileGuid)
}

function Get-LanguageName([UInt16]$LangId) {
    switch ($LangId) {
        0x0404 { return '中文（繁体，台湾）' }
        0x0804 { return '中文（简体，中国）' }
        0x0C04 { return '中文（繁体，香港）' }
        0x1004 { return '中文（简体，新加坡）' }
        0x1404 { return '中文（繁体，澳门）' }
        default { return ('语言 ID 0x{0:X4}' -f $LangId) }
    }
}

function Get-ChineseTsfProfiles([switch]$SimplifiedOnly) {
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($view in Get-RegistryViews) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $view
        )
        try {
            $tipRoot = $baseKey.OpenSubKey($script:TipRootPath, $false)
            if ($null -eq $tipRoot) {
                continue
            }

            try {
                foreach ($clsidName in $tipRoot.GetSubKeyNames()) {
                    $clsid = [Guid]::Empty
                    if (-not [Guid]::TryParse($clsidName, [ref]$clsid)) {
                        continue
                    }

                    $languageRoot = $tipRoot.OpenSubKey("$clsidName\LanguageProfile", $false)
                    if ($null -eq $languageRoot) {
                        continue
                    }

                    try {
                        foreach ($languageName in $languageRoot.GetSubKeyNames()) {
                            if ($languageName -notmatch '^0x[0-9a-fA-F]{1,8}$') {
                                continue
                            }

                            try {
                                $languageNumber = [Convert]::ToUInt32($languageName.Substring(2), 16)
                            }
                            catch {
                                continue
                            }

                            if ($languageNumber -gt [UInt16]::MaxValue) {
                                continue
                            }

                            $langId = [UInt16]$languageNumber
                            if (($langId -band 0x03FF) -ne 0x0004) {
                                continue
                            }

                            if ($SimplifiedOnly -and
                                $langId -ne 0x0804 -and $langId -ne 0x1004) {
                                continue
                            }

                            $profileRoot = $languageRoot.OpenSubKey($languageName, $false)
                            if ($null -eq $profileRoot) {
                                continue
                            }

                            try {
                                foreach ($profileName in $profileRoot.GetSubKeyNames()) {
                                    $profileGuid = [Guid]::Empty
                                    if (-not [Guid]::TryParse($profileName, [ref]$profileGuid)) {
                                        continue
                                    }

                                    $profileKey = $profileRoot.OpenSubKey($profileName, $false)
                                    if ($null -eq $profileKey) {
                                        continue
                                    }

                                    try {
                                        $valueNames = @($profileKey.GetValueNames())
                                        $descriptionExists = $valueNames -contains 'Description'
                                        $description = if ($descriptionExists) {
                                            [string]$profileKey.GetValue('Description', $null,
                                                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                                        }
                                        else {
                                            $null
                                        }

                                        $descriptionKind = if ($descriptionExists) {
                                            $profileKey.GetValueKind('Description').ToString()
                                        }
                                        else {
                                            $null
                                        }

                                        $enable = if ($valueNames -contains 'Enable') {
                                            $profileKey.GetValue('Enable')
                                        }
                                        else {
                                            $null
                                        }

                                        $relativePath = '{0}\{1}\LanguageProfile\{2}\{3}' -f `
                                            $script:TipRootPath, $clsidName, $languageName, $profileName

                                        $entries.Add([pscustomobject]@{
                                            Identity          = New-ProfileIdentity $clsid $langId $profileGuid
                                            Clsid             = $clsid
                                            LangId            = $langId
                                            ProfileGuid       = $profileGuid
                                            Description       = $description
                                            DescriptionExists = $descriptionExists
                                            DescriptionKind   = $descriptionKind
                                            Enable            = $enable
                                            View              = $view.ToString()
                                            Path              = $relativePath
                                        })
                                    }
                                    finally {
                                        $profileKey.Dispose()
                                    }
                                }
                            }
                            finally {
                                $profileRoot.Dispose()
                            }
                        }
                    }
                    finally {
                        $languageRoot.Dispose()
                    }
                }
            }
            finally {
                $tipRoot.Dispose()
            }
        }
        finally {
            $baseKey.Dispose()
        }
    }

    $profiles = foreach ($group in ($entries | Group-Object Identity)) {
        $groupEntries = @($group.Group)
        $descriptions = @(
            $groupEntries |
                ForEach-Object { $_.Description } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )

        $name = if ($descriptions.Count -gt 0) {
            $descriptions -join ' / '
        }
        else {
            '（缺少 Description）'
        }

        $enableValues = @(
            $groupEntries |
                ForEach-Object { $_.Enable } |
                Where-Object { $null -ne $_ }
        )
        $enabled = if ($enableValues -contains 1) {
            '是'
        }
        elseif ($enableValues.Count -gt 0) {
            '否'
        }
        else {
            '未知'
        }

        $first = $groupEntries[0]
        [pscustomobject]@{
            Identity    = $first.Identity
            Name        = $name
            LangId      = $first.LangId
            Language    = Get-LanguageName $first.LangId
            Clsid       = $first.Clsid
            ProfileGuid = $first.ProfileGuid
            Enabled     = $enabled
            Views       = (@($groupEntries.View | Select-Object -Unique) -join ',')
            Entries     = $groupEntries
        }
    }

    return @($profiles | Sort-Object Name, Identity)
}

function Show-Profiles([object[]]$Profiles) {
    Write-Host ''
    Write-Host '已注册的简体中文 TSF 输入法：' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Profiles.Count; $i++) {
        $profile = $Profiles[$i]
        Write-Host ('[{0}] {1}' -f ($i + 1), $profile.Name) -ForegroundColor Yellow
        Write-Host ('    语言={0} (0x{1:X4})  已启用={2}  注册表视图={3}' -f `
            $profile.Language, $profile.LangId, $profile.Enabled, $profile.Views)
        Write-Host ('    CLSID={0}' -f (Format-Guid $profile.Clsid))
        Write-Host ('    Profile={0}' -f (Format-Guid $profile.ProfileGuid))
    }
    Write-Host ''
}

function Get-CurrentChineseProfile([object[]]$Profiles) {
    Initialize-TsfInterop
    $active = [ImeAliasTool.TsfProfiles]::GetActiveProfile()

    if ($active.dwProfileType -ne 1) {
        throw '当前激活的是键盘布局，不是 TSF 输入法。'
    }

    if (($active.langid -band 0x03FF) -ne 0x0004) {
        throw ('当前激活的 TSF Profile 不是中文输入法（LANGID=0x{0:X4}）。' -f $active.langid)
    }

    $identity = New-ProfileIdentity $active.clsid $active.langid $active.guidProfile
    $match = @($Profiles | Where-Object { $_.Identity -eq $identity })
    if ($match.Count -eq 0) {
        throw ('在 HKLM 中找不到当前激活的中文 TSF Profile：{0}' -f $identity)
    }

    return $match[0]
}

function Read-ProfileSelection([object[]]$Profiles, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = Read-Host '请输入编号（例如 1,3 或 1-4），A=全选，Q=退出'
    }

    $Value = $Value.Trim()
    if ($Value -match '^(?i:q|quit)$') {
        return @()
    }
    if ($Value -match '^(?i:a|all|\*)$') {
        return @($Profiles)
    }

    $Value = $Value.Replace([string][char]0xFF0C, ',')
    $indexes = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($tokenValue in ($Value -split '[,\s]+' | Where-Object { $_ })) {
        $token = $tokenValue.Trim()
        if ($token -match '^(\d+)\s*-\s*(\d+)$') {
            $start = [int]$Matches[1]
            $end = [int]$Matches[2]
            if ($start -gt $end) {
                throw "编号范围不能倒序：$token"
            }
            foreach ($number in $start..$end) {
                if ($number -lt 1 -or $number -gt $Profiles.Count) {
                    throw "编号超出范围：$number"
                }
                [void]$indexes.Add($number - 1)
            }
        }
        elseif ($token -match '^\d+$') {
            $number = [int]$token
            if ($number -lt 1 -or $number -gt $Profiles.Count) {
                throw "编号超出范围：$number"
            }
            [void]$indexes.Add($number - 1)
        }
        else {
            throw "无法识别的选择：$token"
        }
    }

    if ($indexes.Count -eq 0) {
        throw '没有选择任何输入法。'
    }

    return @($indexes | Sort-Object | ForEach-Object { $Profiles[$_] })
}

function Get-RegistryBaseKey([string]$View) {
    $registryView = [Microsoft.Win32.RegistryView]::$View
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        $registryView
    )
}

function Set-DescriptionValue([object]$Entry, [string]$Value) {
    $baseKey = Get-RegistryBaseKey $Entry.View
    try {
        $key = $baseKey.OpenSubKey($Entry.Path, $true)
        if ($null -eq $key) {
            throw ('注册表项不存在：HKLM\{0}（{1}）' -f $Entry.Path, $Entry.View)
        }
        try {
            $key.SetValue('Description', $Value, [Microsoft.Win32.RegistryValueKind]::String)
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Restore-DescriptionValue([object]$Entry) {
    $baseKey = Get-RegistryBaseKey $Entry.View
    try {
        $key = $baseKey.OpenSubKey($Entry.Path, $true)
        if ($null -eq $key) {
            return
        }
        try {
            if ($Entry.DescriptionExists) {
                $kind = [Microsoft.Win32.RegistryValueKind]::$($Entry.DescriptionKind)
                $key.SetValue('Description', $Entry.Description, $kind)
            }
            else {
                $key.DeleteValue('Description', $false)
            }
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Get-ProfileGuidHex([string]$Path) {
    # 注册表条目路径的最后一段是 Profile GUID，去掉大括号和连字符得到 32 位十六进制串
    $leaf = Split-Path $Path -Leaf
    return ($leaf -replace '[{}\-]', '').ToUpperInvariant()
}

function Get-BackupItems([string]$FilePath) {
    try {
        $backup = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return @()
    }
    return @($backup.items)
}

function Find-BackupsForPath([string]$Path) {
    # 按备份内容（注册表路径）查找：同一输入法的既有备份文件
    if (-not (Test-Path -LiteralPath $script:BackupDir -PathType Container)) {
        return @()
    }
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($file in (Get-ChildItem -LiteralPath $script:BackupDir -Filter 'ime-description-*.json' -File)) {
        foreach ($item in (Get-BackupItems $file.FullName)) {
            if ([string]$item.path -eq $Path) {
                $matches.Add($file)
                break
            }
        }
    }
    return $matches
}

function Update-BackupAlias([string]$FilePath, [string]$NewAlias) {
    # 保留备份中的原始恢复值不变，仅把「当时改为」更新为最新的别名
    $backup = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $backup.newAlias = $NewAlias
    $backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $FilePath -Encoding UTF8
}

function Get-UniqueBackupFileName([string]$Path) {
    # 文件名使用 Profile GUID 前 8 位；若被其他输入法的备份撞名（GUID 前缀冲突），
    # 逐步加长 GUID 片段直到唯一，不覆盖其他输入法的备份
    $guidHex = Get-ProfileGuidHex $Path
    foreach ($length in 8, 12, 16, 20, 24, 28, 32) {
        if ($length -gt $guidHex.Length) {
            break
        }
        $fileName = 'ime-description-{0}.json' -f $guidHex.Substring(0, $length)
        $fullPath = Join-Path $script:BackupDir $fileName
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            return $fileName
        }
        # 同名文件内容属于当前条目时不算冲突（调用方已按内容跳过，这里只是兜底）
        $samePath = $false
        foreach ($item in (Get-BackupItems $fullPath)) {
            if ([string]$item.path -eq $Path) {
                $samePath = $true
                break
            }
        }
        if ($samePath) {
            return $fileName
        }
    }
    # 极端情况：完整 GUID 仍冲突，追加随机后缀保底
    return 'ime-description-{0}-{1}.json' -f `
        $guidHex, ([Guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Save-Backup([object[]]$Entries, [string]$NewAlias) {
    # 同一输入法只保留最早的一份备份：反复修改 A → B → C 时不再生成新备份，
    # 恢复时始终回到最开始的原始值 A；但会把已有备份中的别名更新为最新值
    [void](New-Item -ItemType Directory -Path $script:BackupDir -Force)

    $backupPaths = New-Object System.Collections.Generic.List[string]
    foreach ($group in ($Entries | Group-Object Path)) {
        $profilePath = $group.Name
        $existing = @(Find-BackupsForPath $profilePath)
        if ($existing.Count -gt 0) {
            foreach ($file in $existing) {
                Update-BackupAlias -FilePath $file.FullName -NewAlias $NewAlias
            }
            Write-Host ('  该输入法的最早备份已存在，已将备份中的别名更新为最新值（恢复值不变）：HKLM\{0}' -f $profilePath)
            continue
        }

        $backupPath = Join-Path $script:BackupDir (Get-UniqueBackupFileName $profilePath)
        $items = foreach ($entry in $group.Group) {
            [ordered]@{
                view              = $entry.View
                path              = $entry.Path
                descriptionExists = [bool]$entry.DescriptionExists
                description       = $entry.Description
                descriptionKind   = $entry.DescriptionKind
            }
        }
        $backup = [ordered]@{
            formatVersion = 1
            createdAt     = (Get-Date).ToString('o')
            computerName  = $env:COMPUTERNAME
            newAlias      = $NewAlias
            items         = @($items)
        }
        $backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        $backupPaths.Add($backupPath)
    }
    return @($backupPaths)
}

function Get-LiveDescription([string]$View, [string]$Path) {
    # 读取注册表中该条目当前的 Description 值（只读）
    $baseKey = Get-RegistryBaseKey $View
    try {
        $key = $baseKey.OpenSubKey($Path, $false)
        if ($null -eq $key) {
            return [pscustomobject]@{ KeyExists = $false; Exists = $false; Value = $null }
        }
        try {
            $names = @($key.GetValueNames())
            if ($names -contains 'Description') {
                return [pscustomobject]@{
                    KeyExists = $true
                    Exists    = $true
                    Value     = [string]$key.GetValue('Description', $null,
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                }
            }
            return [pscustomobject]@{ KeyExists = $true; Exists = $false; Value = $null }
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Select-BackupFromMenu {
    if (-not (Test-Path -LiteralPath $script:BackupDir -PathType Container)) {
        throw ('备份目录不存在：{0}' -f $script:BackupDir)
    }

    $files = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'ime-description-*.json' -File |
        Sort-Object Name -Descending)
    if ($files.Count -eq 0) {
        throw ('备份目录中没有可恢复的备份：{0}' -f $script:BackupDir)
    }

    $backups = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        try {
            $backup = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-Host ('{0}（无法解析，已跳过）' -f $file.Name) -ForegroundColor DarkYellow
            continue
        }
        $backups.Add([pscustomobject]@{ File = $file; Backup = $backup })
    }
    if ($backups.Count -eq 0) {
        throw '备份目录中的文件都无法解析。'
    }

    Write-Host ''
    Write-Host '可恢复的备份（新 → 旧）：' -ForegroundColor Cyan
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $entry = $backups[$i]
        $backup = $entry.Backup
        Write-Host ('[{0}] {1}' -f ($i + 1), $entry.File.Name) -ForegroundColor Yellow
        Write-Host ('    备份时间={0}  当时改为={1}' -f $backup.createdAt, $backup.newAlias)
        foreach ($item in @($backup.items)) {
            $live = Get-LiveDescription -View ([string]$item.view) -Path ([string]$item.path)
            $currentText = if (-not $live.KeyExists) {
                '（注册表项当前不存在）'
            }
            elseif (-not $live.Exists) {
                '（当前无 Description 值）'
            }
            else {
                $live.Value
            }
            $restoreText = if ([bool]$item.descriptionExists) {
                [string]$item.description
            }
            else {
                '（恢复时删除 Description）'
            }
            Write-Host ('    - HKLM\{0} ({1})' -f $item.path, $item.view)
            Write-Host ('      {0}  →  {1}' -f $currentText, $restoreText)
        }
    }
    Write-Host ''

    $choiceInput = Read-Host '请输入要恢复的备份编号，Q=取消'
    if ($null -eq $choiceInput) {
        # stdin 被重定向且已读完（EOF）时 Read-Host 返回 $null，按取消处理
        return $null
    }
    $choice = $choiceInput.Trim()
    if ($choice -eq '' -or $choice -match '^(?i:q|quit)$') {
        return $null
    }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or `
        $number -lt 1 -or $number -gt $backups.Count) {
        throw ('无效的编号：{0}' -f $choice)
    }
    return $backups[$number - 1].File.FullName
}

try {
    Use-CjkConsoleFont
    if ($FixConsoleFontOnly) {
        exit 0
    }
    if ($LauncherMenu) {
        exit (Show-LauncherMenu)
    }

    if ($RestoreMenu) {
        # 注意：$Restore 声明为 [string]，直接赋 $null 会被强转为空字符串，
        # 因此先用无类型变量接返回值再判断
        $selectedBackup = Select-BackupFromMenu
        if ($null -eq $selectedBackup) {
            Write-Host '已取消。'
            exit 0
        }
        $Restore = $selectedBackup
    }

    if (-not [string]::IsNullOrWhiteSpace($Restore)) {
        if (-not (Test-Path -LiteralPath $Restore -PathType Leaf)) {
            throw ('备份文件不存在：{0}' -f $Restore)
        }

        $backup = Get-Content -LiteralPath $Restore -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @($backup.items)
        if ($items.Count -eq 0) {
            throw '备份文件中没有可恢复的条目。'
        }

        Write-Host ''
        Write-Host ('备份时间：{0}（当时改为：{1}）' -f $backup.createdAt, $backup.newAlias) -ForegroundColor Cyan
        Write-Host ('将恢复 {0} 个注册表值：' -f $items.Count) -ForegroundColor Cyan
        foreach ($item in $items) {
            $oldDesc = if ($item.descriptionExists) { $item.description } else { '（原本不存在，恢复时将删除 Description）' }
            Write-Host ('  - HKLM\{0} ({1}) → {2}' -f $item.path, $item.view, $oldDesc)
        }

        if ($DryRun) {
            Write-Host '模拟运行完成：没有修改任何注册表值。' -ForegroundColor Green
            exit 0
        }

        if (-not (Test-IsAdministrator)) {
            throw '恢复注册表需要管理员权限。请以管理员身份打开 PowerShell 后重新运行。'
        }

        if (-not $NoConfirm) {
            $confirmation = (Read-Host '是否继续恢复？请输入 Y 或 YES').Trim()
            if ($confirmation -notmatch '^(?i:y|yes)$') {
                Write-Host '已取消。'
                exit 0
            }
        }

        foreach ($item in $items) {
            Restore-DescriptionValue ([pscustomobject]@{
                View              = [string]$item.view
                Path              = [string]$item.path
                DescriptionExists = [bool]$item.descriptionExists
                Description       = $item.description
                DescriptionKind   = $item.descriptionKind
            })
            Write-Host ('已恢复 {0}：HKLM\{1}' -f $item.view, $item.path)
        }

        Write-Host ''
        Write-Host '恢复完成。测试前请重启目标程序。' -ForegroundColor Green
        exit 0
    }

    if (-not $DryRun -and -not (Test-IsAdministrator)) {
        throw '需要管理员权限。请以管理员身份打开 PowerShell，切换到目标输入法后重新运行此脚本。'
    }

    if ($Mode -eq 'Interactive') {
        Write-Host '1. 修改当前激活的中文 TSF 输入法'
        Write-Host '2. 列出简体中文 TSF 输入法，由用户选择（支持多选和全选）'
        $menuChoice = (Read-Host '请选择 1 或 2').Trim()
        switch ($menuChoice) {
            '1' { $Mode = 'Current' }
            '2' { $Mode = 'Select' }
            default { throw "无效的菜单选项：$menuChoice" }
        }
    }

    $profiles = if ($Mode -eq 'Select') {
        @(Get-ChineseTsfProfiles -SimplifiedOnly)
    }
    else {
        @(Get-ChineseTsfProfiles)
    }

    if ($profiles.Count -eq 0) {
        if ($Mode -eq 'Select') {
            throw '没有找到已注册的简体中文 TSF 输入法。'
        }
        throw '没有找到已注册的中文 TSF 输入法。'
    }

    if ($Mode -eq 'Current') {
        $targets = @(Get-CurrentChineseProfile $profiles)
    }
    else {
        Show-Profiles $profiles
        $targets = @(Read-ProfileSelection $profiles $Selection)
        if ($targets.Count -eq 0) {
            Write-Host '已取消。'
            exit 0
        }
    }

    if ([string]::IsNullOrWhiteSpace($Alias)) {
        $enteredAlias = Read-Host "请输入新的 Description 别名（直接回车使用：$script:DefaultAlias）"
        $Alias = if ([string]::IsNullOrWhiteSpace($enteredAlias)) {
            $script:DefaultAlias
        }
        else {
            $enteredAlias.Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($Alias)) {
        throw 'Description 别名不能为空。'
    }

    Write-Host ''
    Write-Host ('新的 Description：{0}' -f $Alias) -ForegroundColor Cyan
    Write-Host '将要修改的输入法：' -ForegroundColor Cyan
    foreach ($target in $targets) {
        Write-Host ('  - {0} (0x{1:X4}, {2})' -f `
            $target.Name, $target.LangId, $target.Views) -ForegroundColor Yellow
    }

    $targetEntries = @(
        $targets |
            ForEach-Object { $_.Entries } |
            Sort-Object View, Path -Unique
    )
    Write-Host ('将要修改的注册表项数量：{0}' -f $targetEntries.Count)

    if ($DryRun) {
        Write-Host '模拟运行完成：没有修改任何注册表值。' -ForegroundColor Green
        exit 0
    }

    if (-not $NoConfirm) {
        $confirmation = (Read-Host '是否继续？请输入 Y 或 YES').Trim()
        if ($confirmation -notmatch '^(?i:y|yes)$') {
            Write-Host '已取消。'
            exit 0
        }
    }

    $backupPaths = @(Save-Backup $targetEntries $Alias)
    if ($backupPaths.Count -eq 0) {
        Write-Host '所有目标输入法的最早备份均已存在，未创建新备份。'
    }
    else {
        foreach ($savedBackup in $backupPaths) {
            Write-Host ('备份文件：{0}' -f $savedBackup)
        }
    }

    $changedEntries = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($entry in $targetEntries) {
            Set-DescriptionValue $entry $Alias
            $changedEntries.Add($entry)
            Write-Host ('已修改 {0}：HKLM\{1}' -f $entry.View, $entry.Path)
        }
    }
    catch {
        Write-Warning '写入失败，正在回滚本次运行已经修改的值。'
        for ($i = $changedEntries.Count - 1; $i -ge 0; $i--) {
            try {
                Restore-DescriptionValue $changedEntries[$i]
            }
            catch {
                Write-Warning ('回滚失败 {0}：HKLM\{1}' -f `
                    $changedEntries[$i].View, $changedEntries[$i].Path)
            }
        }
        throw
    }

    Write-Host ''
    Write-Host '修改完成。测试前请重启目标程序。' -ForegroundColor Green
    Write-Host '通常不需要重启 Windows。'
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}