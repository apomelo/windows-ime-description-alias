# Windows 中文输入法 Description 修改工具

这是一个独立的 PowerShell 脚本（附批处理启动器 `Set-ChineseImeAlias.bat`），用于修改 Windows TSF（Text Services Framework）中文输入法 Profile 的注册表 `Description`。

适用于部分通过输入法名称白名单决定兼容路径的程序。例如，可以把目标输入法的 `Description` 临时改为程序已识别的名称。脚本默认使用 `搜狗拼音输入法`，也可以在运行时输入其他名称。

自动备份与一键恢复：首次修改某个输入法前，自动将其原始 Description 值备份为 JSON 文件（同一输入法只保留最早的一份备份），支持通过 -Restore 参数或 -RestoreMenu 交互菜单随时恢复；反复修改（A → B → C）时始终恢复到最开始的原始值 A，避免误操作导致输入法名称永久丢失。

> 修改名称只能影响程序对输入法的识别结果，不能保证任意输入法都兼容目标程序的候选窗口或候选数据接口。

## 系统要求

- Windows
- Windows PowerShell 5.1 或 PowerShell 7+
- 管理员权限
- 目标输入法必须是已注册的 TSF 输入法

脚本不联网，不安装软件，只修改所选 Profile 的注册表 `Description`。

## 使用方法

### 方式一：双击批处理启动器（推荐）

双击 `Set-ChineseImeAlias.bat`，依次回答两个问题：

1. 操作模式：`1` 修改输入法 Description（默认），`2` 从备份恢复，`Q` 退出；
2. 是否以 DryRun 模拟运行（只显示目标，不写入注册表）。

实际写入需要管理员权限：选择非 DryRun 时启动器会自动弹出 UAC 提权，并在提权后的窗口中继续执行已作出的选择（DryRun 为只读操作，不提权）。

选择恢复时，会列出脚本目录 `backup` 文件夹中的全部备份：每个备份的备份时间、当时改成的别名、涉及的注册表条目（路径和视图），以及每个条目实时的「当前值 → 恢复值」对照，输入编号即可恢复。

### 方式二：命令行运行

以管理员身份打开 PowerShell，然后运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Set-ChineseImeAlias.ps1
```

脚本提供两个选项：

### 1. 修改当前激活的中文输入法

修改当前 PowerShell 窗口所使用的中文 TSF 输入法，支持简体和繁体中文 Profile。

使用前请先在 PowerShell 中切换到目标输入法。目标程序不需要运行，也不需要位于前台；之后由用户保证目标程序使用同一个输入法即可。

以下情况会停止修改：

- 当前使用的是非中文输入法；
- 当前输入源只是普通键盘布局，不是 TSF 输入法；
- 无法在注册表中找到对应的 CLSID、语言 ID 和 Profile GUID。

### 2. 列出简体中文输入法并选择

候选列表只包含以下简体中文语言 Profile：

- `0x0804`：中文（简体，中国）
- `0x1004`：中文（简体，新加坡）

支持以下选择格式：

```text
1        选择一个
1,3      选择多个
1-4      选择一个范围
A        全选列表中的全部 Profile
Q        退出
```

列表会同时显示 Profile 的启用状态。`A` 表示选择列表中的全部已注册简体中文 Profile，包括显示为“未启用”的系统 Profile；写入前脚本仍会显示目标并要求确认。

## Description 别名

脚本会提示输入新的 `Description`。直接按回车时使用默认值：

```text
搜狗拼音输入法
```

也可以通过参数指定：

```powershell
.\Set-ChineseImeAlias.ps1 -Mode Current -Alias '搜狗拼音输入法'
.\Set-ChineseImeAlias.ps1 -Mode Select -Selection '1,3' -Alias '搜狗拼音输入法'
.\Set-ChineseImeAlias.ps1 -Mode Select -Selection A -Alias '搜狗拼音输入法'
```

## 备份与恢复

备份包含注册表视图、路径、原始值和原始值类型。如果一次操作中途写入失败，脚本会尝试立即回滚本次已经修改的项目。

如需日后恢复，可根据 JSON 中每个 `items` 项的 `view`、`path`、`description` 和 `descriptionKind`，以管理员身份恢复对应的 `Description`。请不要删除仍需使用的备份。

### 自动备份
脚本在**实际写入注册表之前**，会自动将目标 Profile 的原始 `Description` 值（包括值是否存在、数据类型）保存为 JSON 文件。

- **备份位置**：固定为脚本所在目录下的 `.\backup\` 文件夹
- **文件命名格式**：`ime-description-<ProfileGUID前8位>.json`，GUID 片段取自注册表条目路径的最后一段，便于识别备份对应的输入法
- **单份备份**：同一输入法只保留最早的一份备份（按备份内容中的注册表路径判断，而不是文件名）。反复修改（A → B → C）时不会生成新备份，只会把已有备份中的「当时改为」更新为最新别名；恢复时始终回到最开始的原始值 A
- **GUID 前缀冲突**：理论上不同输入法的 Profile GUID 前 8 位可能相同（实际概率极低）。撞名时脚本会自动加长 GUID 片段（12、16、20……直到完整 32 位），直到文件名唯一，不会覆盖其他输入法的备份

### 恢复备份

交互式列出并选择备份（推荐，与启动器的「从备份恢复」相同）：

```powershell
.\Set-ChineseImeAlias.ps1 -RestoreMenu
```

列表会显示每个备份的备份时间、当时改成的别名、注册表条目（路径和视图），以及实时的「当前值 → 恢复值」对照。

也可以直接用 `-Restore` 指定备份文件路径：

```powershell
.\Set-ChineseImeAlias.ps1 -Restore '.\backup\ime-description-3D02CAB6.json'
```

## 运行命令和参数

可用参数：

| 参数 | 说明 |
| --- | --- |
| `-Mode Interactive` | 显示交互菜单，默认值 |
| `-Mode Current` | 修改当前激活的中文 TSF 输入法 |
| `-Mode Select` | 列出简体中文 TSF 输入法并选择 |
| `-Selection` | 非交互式指定编号、范围或 `A` |
| `-Alias` | 指定新的 `Description` |
| `-NoConfirm` | 跳过最终确认 |
| `-DryRun` | 只显示目标，不写入注册表 |
| `-Restore` | 指定备份 JSON 文件路径，恢复注册表 `Description` 值 |
| `-RestoreMenu` | 列出 `backup` 目录中的备份（含当前值 → 恢复值对照），由用户选择恢复 |

建议首次运行时先检查目标：

```powershell
.\Set-ChineseImeAlias.ps1 -Mode Current -DryRun
```

## 不依赖脚本的一句话命令

以下命令可直接粘贴到**管理员 PowerShell** 中运行，不依赖本仓库脚本或网络。它们会立即把 `Description` 修改为 `搜狗拼音输入法`，不进行确认，也不会创建备份。

### 自动修改当前激活的中文输入法

执行前，先在当前 PowerShell 窗口中切换到目标中文 TSF 输入法。该命令支持简体和繁体中文输入法，并修改实际存在的 32 位和 64 位注册表视图：

```powershell
if(-not('ImeOneLine.T' -as [type])){Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;namespace ImeOneLine{[StructLayout(LayoutKind.Sequential)]public struct P{public uint t;public ushort l;public Guid c;public Guid p;public Guid k;public IntPtr s;public uint a;public IntPtr h;public uint f;}[ComImport,Guid("71C6E74C-0F28-11D8-A82A-00065B84435C"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface I{[PreserveSig]int A();[PreserveSig]int B();[PreserveSig]int C();[PreserveSig]int D();[PreserveSig]int E();[PreserveSig]int F();[PreserveSig]int G();[PreserveSig]int H(ref Guid g,out P p);}public static class T{public static P Get(){object o=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("33C53A50-F456-4884-B049-85FD643ECFED")));try{Guid g=new Guid("34745C63-B2F0-4784-8B67-5E12C8701A31");P p;int h=((I)o).H(ref g,out p);if(h!=0)throw new COMException("GetActiveProfile failed",h);return p;}finally{Marshal.FinalReleaseComObject(o);}}}}'};$p=[ImeOneLine.T]::Get();if($p.t-ne 1-or($p.l-band 0x3ff)-ne 4){throw '当前激活的不是中文 TSF 输入法'};$path='SOFTWARE\Microsoft\CTF\TIP\{0}\LanguageProfile\0x{1:X8}\{2}'-f $p.c.ToString('B'),[uint32]$p.l,$p.p.ToString('B');$views=@([Microsoft.Win32.RegistryView]::Registry32);if([Environment]::Is64BitOperatingSystem){$views=@([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)};$n=0;foreach($v in $views){$b=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$v);try{$k=$b.OpenSubKey($path,$true);if($k){try{$k.SetValue('Description','搜狗拼音输入法',[Microsoft.Win32.RegistryValueKind]::String);$n++}finally{$k.Dispose()}}}finally{$b.Dispose()}};if(!$n){throw '没有找到对应的输入法注册表项'};Write-Host "修改完成，共写入 $n 个注册表视图" -ForegroundColor Green
```

### 固定修改小狼毫简体中文 Profile

该命令不检查当前输入法，直接修改小狼毫的简体中文（`0x0804`）Profile：

```powershell
$p='SOFTWARE\Microsoft\CTF\TIP\{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}\LanguageProfile\0x00000804\{3D02CAB6-2B8E-4781-BA20-1C9267529467}';$vs=if([Environment]::Is64BitOperatingSystem){@([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)}else{@([Microsoft.Win32.RegistryView]::Registry32)};$n=0;foreach($v in $vs){$b=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$v);try{$k=$b.OpenSubKey($p,$true);if($k){try{$k.SetValue('Description','搜狗拼音输入法',[Microsoft.Win32.RegistryValueKind]::String);$n++}finally{$k.Dispose()}}}finally{$b.Dispose()}};Write-Host "修改完成，共写入 $n 个注册表视图" -ForegroundColor Green
```

上述小狼毫命令使用官方安装版本的固定 TSF 标识。第三方修改版如果更换了 CLSID 或 Profile GUID，则不适用。

## 修改范围

脚本根据 TSF Profile 的以下标识定位注册表项：

- CLSID
- Language ID
- Profile GUID

对应路径为：

```text
HKLM\SOFTWARE\Microsoft\CTF\TIP\{CLSID}\LanguageProfile\0xLLLLLLLL\{ProfileGUID}
```

在 64 位 Windows 上，脚本会修改实际存在的 64 位和 32 位注册表视图，但只写入 `Description`，不会修改 CLSID、Profile GUID、DLL 路径或启用状态，也不会创建不存在的 Profile。

## 注意事项

- 修改对整个输入法 Profile 生效，不是仅对某个游戏或程序生效。
- 输入法自身的安装、升级、修复或重新注册可能覆盖 `Description`。
- Windows 更新可能恢复微软系统输入法的注册信息。
- 某些系统 Profile 可能受额外权限保护；写入失败时脚本会报错并回滚。
- 修改后应重启目标程序。通常不需要重启 Windows；如果程序或 TSF 缓存了信息，可以切换一次输入法、注销或重启后再测试。
- 旧版控制台（conhost）的输出区域不做字体回退：在系统区域为英文的机器上，默认字体不含中文字形，中文会显示为 `?`。脚本启动时会自动把当前控制台窗口的字体切换为系统自带的新宋体（仅影响当前窗口，不影响其他程序）。
- 不要在不了解用途时使用 `A` 全选。

## 仓库内容

```text
README.md
Set-ChineseImeAlias.bat     双击启动器（模式选择 + DryRun 选择 + 自动提权）
Set-ChineseImeAlias.ps1
backup/                     自动生成的备份目录
```
