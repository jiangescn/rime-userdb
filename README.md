# Rime 词库同步使用手册

这份仓库用于在多台 Windows 电脑之间同步小狼毫（Weasel）的配置、静态词典和个人输入词频。

以后忘记操作时，只需要看下面的“日常同步”或“新电脑首次使用”即可。

每次正常运行同步脚本，会检查雾凇官方默认分支并增量更新现有基础词典。当前安装的上游提交见 [`RIME_ICE_VERSION.md`](./RIME_ICE_VERSION.md)，文件哈希记录在 `rime-ice-update.json`。

## 最常用的操作

### 当前电脑日常同步

打开 PowerShell，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\rime-userdb\sync-rime.ps1"
```

正常结束时会看到：

```text
Rime and GitHub synchronization completed.
```

这一个命令会同时完成：

1. 从 GitHub 拉取其他电脑上传的最新词库；
2. 导出本机刚刚学习到的词频；
3. 备份本机现有配置；
4. 检查雾凇官方词库，下载固定提交、校验并备份后更新，再把仓库配置和所有电脑的词频合并到 `%APPDATA%\Rime`；
5. 重新部署小狼毫；
6. 将本机合并后的词频和本次官方词库更新提交并推送回 GitHub。

建议在换电脑前、另一台电脑开始工作前，以及积累了一批新词后各运行一次。不要在两台电脑上同时运行，避免 Git 推送冲突。

### 官方词库自动更新

无需新命令：正常同步时自动查询 `iDvel/rime-ice` 的默认分支，锁定一个提交后下载。不会创建定时任务，也不会在日常打字时联网。

- 只更新 `rime-ice-update.json` 记录的 16 个现有中文、英文词典文件。
- 保留 `rime_ice.dict.yaml` 中的词典挂载列表、小鹤双拼、自定义配置、schema、Lua、`word_simp` 和个人词频。上游新增或改名的文件需人工检查后接入。
- 文件哈希与上次记录不符时，保留手工修改并跳过官方更新。
- 官方查询、下载或格式校验失败时，显示警告并使用现有词库继续同步。你自己的 GitHub 仓库拉取失败仍会停止原同步流程。
- 更新前备份到 `%LOCALAPPDATA%\RimeBackups\official-时间-随机编号`；部署失败时恢复本次替换的词典，并尝试重新部署旧版。正常同步的本机备份仍保留在同目录的时间戳子目录中。
- 官方默认分支有新提交但词典内容没变时，仅更新版本记录，避免重复下载该提交。

临时只同步配置和个人词频、跳过官方更新：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\rime-userdb\sync-rime.ps1" -SkipDictionaryUpdate
```

## 新电脑首次使用

### 1. 安装必要软件

安装以下软件：

- [Git for Windows](https://git-scm.com/download/win)
- [小狼毫输入法](https://rime.im/download/)

安装小狼毫后至少启动或使用一次，让它创建默认用户目录：

```text
%APPDATA%\Rime
```

### 2. 配置 GitHub SSH 和 Git 提交身份

本仓库默认使用 SSH 地址：

```text
git@github.com:jiangescn/rime-userdb.git
```

因此新电脑需要先配置可访问该 GitHub 账号的 SSH 密钥。可用下面的命令检查：

```powershell
ssh -T git@github.com
```

还要配置 Git 提交身份；如果这台电脑已经配置过，可以跳过：

```powershell
git config --global user.name "你的 GitHub 用户名"
git config --global user.email "你的 GitHub 邮箱"
```

### 3. 下载并运行引导脚本

在 PowerShell 中完整运行：

```powershell
$script = Join-Path $env:TEMP "sync-rime.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/jiangescn/rime-userdb/main/sync-rime.ps1" -OutFile $script
powershell -NoProfile -ExecutionPolicy Bypass -File $script
```

脚本会自动：

- 将仓库克隆到 `%LOCALAPPDATA%\rime-userdb`；
- 将配置和词典安装到小狼毫默认目录 `%APPDATA%\Rime`；
- 导入仓库里其他电脑的个人词频；
- 重新部署输入法；
- 为这台电脑生成独立的词频快照并推送到 GitHub。

首次部署完成后，后续只需使用“当前电脑日常同步”中的一个命令。

## 多台电脑的正确同步顺序

假设有电脑 A 和电脑 B：

1. 在电脑 A 上运行同步脚本，等它显示完成；
2. 再到电脑 B 上运行同步脚本；
3. 电脑 B 会拉取 A 的新词频，合并后再上传 B 的结果；
4. 回到电脑 A 时再运行一次，即可获得 B 的新词频。

每台电脑必须保留自己的 `installation_id`。不要把其他电脑的 `installation.yaml` 复制过来，也不要手工把两台电脑的设备目录改成同一个名字。

## 到底同步了哪些内容

脚本会同步和安装：

- `cn_dicts/`：中文基础词典；
- `en_dicts/`：英文及中英混合词典；
- `rime_ice.dict.yaml`：雾凇拼音主词典定义；
- `word_simp.dict.yaml`：辅助词典；
- `rime_ice.schema.yaml`、`word_simp.schema.yaml`：输入方案；
- `default.custom.yaml`、`double_pinyin_flypy.custom.yaml`、`weasel.custom.yaml`：方案和外观配置；
- `rime.lua`：日期、时间等 Lua 功能；
- `sync/<设备 ID>/rime_ice.userdb.txt`：各电脑导出的个人输入词频。

以下内容不会提交到 GitHub：

- `%APPDATA%\Rime\build`：可以重新生成的编译缓存；
- `*.userdb`：正在使用的 LevelDB 数据库；
- 日志和临时文件。

这是刻意设计的：可移植、可合并的 `rime_ice.userdb.txt` 会进入 Git，运行中的二进制数据库不会进入 Git。

如果以后新增了一个完全不同的自定义词典，仅把文件放进 `%APPDATA%\Rime` 并不会自动上传；还需要将它加入本仓库及 `sync-rime.ps1` 的配置文件清单。

## 常用路径

| 内容 | 默认位置 |
| --- | --- |
| 小狼毫用户目录 | `%APPDATA%\Rime` |
| 本地 Git 仓库 | `%LOCALAPPDATA%\rime-userdb` |
| 自动备份目录 | `%LOCALAPPDATA%\RimeBackups` |
| 同步脚本 | `%LOCALAPPDATA%\rime-userdb\sync-rime.ps1` |
| 当前设备 ID | `%APPDATA%\Rime\installation.yaml` |
| 当前设备词频快照 | `%APPDATA%\Rime\sync\<设备 ID>\rime_ice.userdb.txt` |

在 PowerShell 中打开这些目录：

```powershell
explorer "$env:APPDATA\Rime"
explorer "$env:LOCALAPPDATA\rime-userdb"
explorer "$env:LOCALAPPDATA\RimeBackups"
```

## 只同步到本机，不上传 GitHub

需要测试配置、暂时不想提交或没有网络时，可以运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\rime-userdb\sync-rime.ps1" -LocalOnly
```

`-LocalOnly` 仍会安装已有配置、合并词频和重新部署，但不会提交或推送本机快照，也不会检查或更新官方词库。

仅在调试时跳过 `git pull`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\rime-userdb\sync-rime.ps1" -SkipPull -LocalOnly
```

日常使用不要加 `-SkipPull`，否则可能漏掉其他电脑的新词频。`-SkipPull` 本身不关闭官方词库检查；只需关闭官方检查时使用 `-SkipDictionaryUpdate`。

## 如何确认同步成功

### 检查本地仓库

```powershell
git -C "$env:LOCALAPPDATA\rime-userdb" status --short --branch
```

正常情况下应类似：

```text
## main...origin/main
```

如果没有额外的 `M` 或 `??` 行，说明本地仓库没有未处理的改动。

### 检查最近提交

```powershell
git -C "$env:LOCALAPPDATA\rime-userdb" log -3 --oneline
```

自动同步产生的提交通常类似：

```text
sync Rime user dictionary from 电脑名
```

也可以打开 GitHub 仓库，确认 `main` 分支出现了当前电脑的最新提交。

## 常见问题

### 提示找不到 Git

安装 Git for Windows，然后关闭并重新打开 PowerShell。

### SSH 或 `Permission denied (publickey)` 错误

说明这台电脑没有配置正确的 GitHub SSH 密钥。先运行：

```powershell
ssh -T git@github.com
```

完成 GitHub SSH 配置后，再重新运行同步脚本。

### 提示仓库存在本地修改

脚本会停止，以免覆盖你手工修改的配置。先查看：

```powershell
git -C "$env:LOCALAPPDATA\rime-userdb" status
```

确认这些修改应当保留后，再手工提交；如果不知道如何处理，不要直接删除或重置，先备份并检查差异。

### Git 推送被拒绝（non-fast-forward）

通常是另一台电脑刚刚推送过。确认另一台电脑已经同步完成，然后在当前电脑重新运行一次正常同步命令。不要使用强制推送。

### 小狼毫没有出现新词或配置

先重新运行同步脚本。脚本本身会执行“用户资料同步”和“重新部署”。如果仍未生效，可以重启小狼毫服务或注销后重新登录 Windows。

### 想恢复同步前的配置

每次运行脚本前，旧配置都会保存在：

```text
%LOCALAPPDATA%\RimeBackups\年月日-时分秒
```

先退出或暂停小狼毫，再从对应时间的备份目录中选择需要恢复的配置文件，复制回 `%APPDATA%\Rime`，最后执行小狼毫“重新部署”。不要删除 `installation.yaml`，否则设备 ID 可能变化。

## 高级参数

```powershell
# 使用非默认 Rime 用户目录
.\sync-rime.ps1 -RimeDir "D:\Rime"

# 手工指定小狼毫部署器
.\sync-rime.ps1 -DeployerPath "C:\path\WeaselDeployer.exe"

# 把本地 Git 仓库存到其他位置
.\sync-rime.ps1 -CheckoutDir "D:\rime-userdb"

# 使用其他仓库地址
.\sync-rime.ps1 -RepositoryUrl "git@github.com:owner/repository.git"
```

一般情况下不需要使用这些参数，保持默认值即可。

## 小鹤音形与个人词条

本仓库同时启用原有小鹤双拼和独立的小鹤音形 `xhup`。在输入框中切到小狼毫，按 F4（或 Ctrl+`）选择“小鹤音形”。

- 保留原有双拼、`rime_ice.userdb` 个人词频和“幽能”配色。
- 音形采用固定码表顺序，保留四码顶屏和分号次选；关闭动态词频、自动造句及编码补全。
- 双拼个人词频仍通过 `sync/<设备 ID>/rime_ice.userdb.txt` 合并；音形不建立 `xhup.userdb`。
- 音形方案、`xhup_dicts/`、专属 Lua 和简码提示随同一次同步安装，不替换原有双拼 schema 或通用 Lua。
- 音形固定于 `RIME_XHUP_VERSION.md` 中的上游提交；雾凇词库更新不会修改音形文件。

个人音形词条可编辑仓库或 Rime 用户目录中的以下文件：

- `xhup_dicts/xhup.user.dict.yaml`：个人词条。
- `xhup_dicts/xhup.user.top.dict.yaml`：优先词条，含上游预设的固顶词。

在文件的 `...` 后添加 `文字<TAB>编码`，TAB 必须为真实制表符，编码为 1–4 位小写字母（也支持分号和单引号）。同码词按码表顺序排列。修改后运行日常同步命令，会保存本机个人词条、合并远端、部署并上传；请按电脑先后同步，不同时编辑同一词条。

脚本使用用户目录 `.xhup-personal-sync.json` 记录上次成功安装的基线。若仓库和本机同一文件都发生不同修改，或缺少基线且两份内容不同，会停止并保留两份文件；先人工合并，再将合并结果放到两处后重新同步。Git 拉取发生词条冲突时也应合并保留双方内容，不强制覆盖。

`-LocalOnly` 会保存本机词条到本地仓库、安装和部署，但不提交或推送；存在个人词条改动时会跳过拉取。新增基线前，请勿删除 `.xhup-personal-sync.json`。

回滚配置时，在退出小狼毫后恢复安装前的 `default.custom.yaml` 和同步脚本，并按新增文件清单移出音形文件；保留原有 `rime_ice.userdb` 以及最新词频快照。完整冷备份包含用户目录、同步仓库、安装目录、注册表目录设置及 SHA-256 清单。不要用其他电脑的 `installation.yaml` 覆盖本机。
