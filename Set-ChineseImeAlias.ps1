#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Current', 'Select')]
    [string]$Mode = 'Interactive',

    [string]$Alias,

    # For non-interactive Select mode: examples "1,3", "1-4", or "A".
    [string]$Selection,

    [switch]$NoConfirm,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TipRootPath = 'SOFTWARE\Microsoft\CTF\TIP'
$script:DefaultAlias = -join @(
    [char]0x641C, [char]0x72D7, [char]0x62FC, [char]0x97F3,
    [char]0x8F93, [char]0x5165, [char]0x6CD5
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

function Save-Backup([object[]]$Entries, [string]$NewAlias) {
    $localAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    $backupDirectory = Join-Path $localAppData 'ImeAliasTool\Backups'
    [void](New-Item -ItemType Directory -Path $backupDirectory -Force)

    $fileName = 'ime-description-{0}-{1}.json' -f `
        (Get-Date -Format 'yyyyMMdd-HHmmss'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $backupPath = Join-Path $backupDirectory $fileName

    $items = foreach ($entry in $Entries) {
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
    return $backupPath
}

try {
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

    $backupPath = Save-Backup $targetEntries $Alias
    Write-Host ('备份文件：{0}' -f $backupPath)

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
