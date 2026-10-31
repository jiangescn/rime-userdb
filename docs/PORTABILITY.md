# 迁移与同步边界

本仓库继续用于同步个人输入资料，并提供新环境所需的整套方案文件。以 Windows 实际使用的配置为基准，不要求不同系统候选顺序逐项相同。

## 共同同步与设备外观

- `rime-files.json` 列出安装文件。双拼基础方案、默认配置、英文方案、反查、Lua、标点、OpenCC 数据和预设词汇均已收录，不再依赖另找一份最新版方案补齐。
- `sync/<设备 ID>/rime_ice.userdb.txt` 是双拼个人词频；由各系统自己的 Rime 合并，不复制运行中的 LevelDB 数据库。
- 个人词条和公共配置支持本机修改后保存回仓库。使用 `.rime-sync-state.json` 判断修改来源；能直接采用的一方变化正常同步，两边发生不同修改时停止，保留双方文件。
- Windows 的 `weasel.yaml`、`weasel.custom.yaml`，macOS 的 `squirrel.yaml`、`squirrel.custom.yaml` 存在 `devices/<设备 ID>/appearance/`。本机改外观只更新自己的设备目录，不修改根目录默认外观或其他电脑的外观。
- 全新设备使用根目录当前默认选项，不增加配置选择向导。现有设备首次接入会先保留已有前端外观文件。Linux 的前端主题由 Fcitx/IBus 管理，不属于 Rime YAML；可由 AI 按实际桌面环境适配并将资料放到本设备目录，不能套用 Windows/macOS 前端文件。
- 方案菜单、标点和按键等公共输入设置仍按仓库配置使用。请通过对应前端文件调整外观，不在公共 schema 中添加强制皮肤。
- `installation.yaml` 和 `user.yaml` 不向其他设备安装；每台设备保留自己的标识及本地状态。

## 版本策略

`RIME_RUNTIME_VERSION.json` 记录此次从 Windows 用户目录或共享目录收录的文件来源与哈希。输入方案和通用 Lua 固定在这份基准，不随日常同步升级。双拼源文件保留 Windows 已在使用的展开配置，没有借迁移重构按键或清理既有翻译器。

为支持空白环境构建，双拼补丁明确列出其实际使用的 `word_simp`、`melt_eng`、`radical_pinyin` 依赖。音形固定码表与动态词频关闭设置保留，方案内的强制皮肤改为继承各设备前端外观。

基础词典继续使用既有官方更新逻辑，仅更新 `rime-ice-update.json` 中的 16 个文件。手工修改的词典不会被官方更新覆盖。更新或部署失败时保留备份并停止或恢复旧文件，不升级方案或 Lua。

## Windows

安装小狼毫和 Git，配置 GitHub 授权后，继续使用原入口及参数：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\rime-userdb\sync-rime.ps1"
```

独立下载的 `sync-rime.ps1` 仍会引导克隆仓库。已有检出升级脚本时，先拉取最新仓库，再运行同步入口。Windows 不增加 Python 运行时要求。

`-RimeDir` 必须与小狼毫注册表中的实际目录一致；该参数不会单独重定向 WeaselDeployer。不要将它当作隔离测试开关。

## macOS

准备好鼠须管（含 Lua 支持及自带的 `rime_deployer`、`rime_dict_manager`）、Git、Python 3.9+ 和 GitHub 授权。默认用户目录为 `~/Library/Rime`，首次引导的检出目录为 `~/Library/Application Support/rime-userdb`。

```bash
bash "$HOME/Library/Application Support/rime-userdb/sync-rime.sh"
```

也可从仓库其他检出位置运行其 `sync-rime.sh`。独立下载该脚本后运行，会克隆默认检出目录。保持 Git 检出与 Rime 用户目录分开。

入口会短暂退出鼠须管，使用鼠须管自带命令行工具进行同步与构建，结束后重新启动。工具会从 `/Library/Input Methods/Squirrel.app/Contents/SharedSupport` 及相邻的 `MacOS` 目录中查找；非标准工具位置可传 `--shared-support`。原生工具负责词频合并，不用文本拼接或简单求和代替 Rime 合并算法。

## Linux 与其他系统

准备含 Lua 支持的 Rime 前端、Git、Python 3.9+ 和原生 `rime_deployer`、`rime_dict_manager` 工具。Linux 默认适配 Fcitx5 用户目录，可指定 IBus：

```bash
bash /path/to/rime-userdb/sync-rime.sh --frontend fcitx5
bash /path/to/rime-userdb/sync-rime.sh --frontend ibus
```

首次使用前查看计划（只读）：

```bash
bash /path/to/rime-userdb/sync-rime.sh --dry-run
```

Linux 日常同步前应退出占用 Rime 数据库的前端；数据库被占用时原生工具会失败，脚本停止。不同桌面的退出、重新启动及主题配置交给实际环境适配，不擅自结束未知进程。其他系统的 AI 应以本仓库文件清单和已有配置为起点，补平台入口，不替换成另一套上游基础方案。

Unix 参数包括 `--rime-dir`、`--skip-pull`、`--skip-dictionary-update`、`--local-only`、`--dry-run`。`--local-only` 会保存本机设置、部署和合并词频，不提交或推送，也不检查官方词典；有待保存设置时会跳过拉取。

## 冲突和恢复

如果首次接入的已有配置与仓库不同，又没有同步基线，脚本会停止；先备份并人工/由 AI 合并两份配置，再同步。不会把陌生的已有配置当成空白环境覆盖。

若修改发生在本机与仓库两处，也会停止并保留双方内容。合并后使两处内容一致，再运行同步即可建立新基线。Git 合并冲突同样需要解决，不能强推或丢弃一方。

回滚时优先恢复配置，保留最新个人数据库和词频快照。若回退了同步脚本，也要使仓库默认配置与本机保持一致，防止下一次同步重新安装新配置。

## 验证范围

- Windows：使用本机 librime，在空白用户目录和空白共享目录中，仅凭本仓库文件构建双拼、音形并恢复词频；验证日期时间、反查、快符及音形固定排序。
- 共享同步逻辑：验证新设备默认值、独立设备标识、配置回传、设备外观隔离、冲突保留和依赖完整性。
- Linux：可在 WSL 运行文件同步逻辑测试及只读计划检查；当前 WSL 没有安装 Rime 前端，不将其视为 Linux 输入法端到端验证。
- macOS：工具路径和调用方式依据鼠须管官方实现，当前没有在本机进行 macOS GUI 实测。

不同平台 Rime 版本及前端可能影响候选展示；本需求保证个人词条和词频互通，不承诺所有候选排序相同。

参考实现：

- [鼠须管原生工具打包](https://github.com/rime/squirrel/blob/master/Makefile)
- [Rime 词典管理工具](https://github.com/rime/librime/blob/1.13.1/tools/rime_dict_manager.cc)
- [Rime 部署工具](https://github.com/rime/librime/blob/1.13.1/tools/rime_deployer.cc)
