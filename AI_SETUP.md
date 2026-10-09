# 给 AI 配置助手的执行指南

目标：把此项目配置为在**使用者自己的 Windows + MATLAB** 中运行。以当前源码和本机检测结果为准。
此文件是公开操作说明，不是某个 Agent 专属 skill。Codex、Claude 或其他有本地文件/终端权限的 AI 均可执行；只有聊天能力的 AI 可以指导用户运行命令。
不要把“帮忙配置的 AI”与“项目运行时调用的 Agent”混为一谈，两者可以不同。

## 输入与边界

先确定项目绝对路径、使用者希望调用的 Agent，以及必要时的模型 ID。不知道用户想用哪个后端时，可先检测，再让用户从检测结果中选择。不要只因为你自己运行在 Codex 内就强制选择 Codex。
仅执行用户授权的配置。检测与安装检查不调用模型；`check --live` 会调用模型并可能计费，只有用户授权验证连接时才运行。
不要在对话或报告中打印密钥、完整环境变量、凭据文件、全局配置全文或本地对话历史。不要替用户选择付费账户。
安装缺失软件或登录需要遵循用户授权和该 Agent 的官方流程；本脚本不会自动安装或登录。

## 第一步：确认文件与 Python

项目根目录应包含 `start_ai.m`、`setup_cli.py`、`matlab/`、`backend/`。不要重建已有项目。
确认系统是 Windows，MATLAB 已安装；已验证版本为 R2026a。
找到 Python 3.11+ 的实际可执行文件。可用 `Get-Command python,python3,py -ErrorAction SilentlyContinue` 获取候选，再运行候选的 `--version`；排除仅指向商店的别名。
若没有受支持的 Python，报告缺失项，按用户授权安装后继续。Python 后端仅使用标准库，不需要创建虚拟环境或安装 Engine。

以下命令是 **PowerShell**。把两个路径替换为本机确认过的绝对路径，不要照抄占位符：

```powershell
$projectRoot = 'D:\projects\matlab-ai-bridge'
$pythonExe = 'C:\实际安装位置\python.exe'
& $pythonExe --version
& $pythonExe -B (Join-Path $projectRoot 'setup_cli.py') discover
```

`discover` 输出 JSON，检查 `ok`、`python_executable`、`agents[].available`、`agents[].executable`、`agents[].node_executable` 和 `suggested_model`。
检测只查 PATH 和常见用户安装位置。未检测到不代表没有安装；可根据用户提供的位置检查原生程序或 JS 入口。
所有 CLI 命令成功退出码为 0，失败为 1；命令参数语法错误由 argparse 返回 2。不要只看进程是否启动，应解析 JSON 并检查 `ok`。
`--output '<报告路径>'` 可把相同 JSON 写入指定文件；父目录需已存在，避免覆盖用户已有文件。

## 第二步：检查已有配置，选后端

目标配置固定为 `<项目目录>/config.local.json`。
若已有配置，只读取本次需要的路径、后端、模型和等待字段；保留未知字段。配置脚本不会回显完整配置。
如果旧配置有效且已满足用户要求，直接跳到安装检查，不要重写。
JSON 损坏时脚本拒绝覆盖：先备份，再按实际问题修复。不要把损坏配置当成空白配置直接覆盖。

后端名称：`codex`、`claude`、`deepseek_harness`。DeepSeek 模型通过 Codex provider 调用时仍属于 `codex`。
Claude 空模型使用其默认模型。Codex 可从自己的配置里获取候选模型；没有候选时必须让用户提供/确认有效模型 ID。
DSH 属于实验适配，必须填写模型 ID；当前仅支持其 `deepseek-official` provider。未知 Agent 不可仅靠改可执行文件名接入，必须新增协议适配器。

## 第三步：写入配置

Codex 示例（模型 ID 用用户确认的真实值替换；省略 `--agent` 时会自动检测）：

```powershell
& $pythonExe -B (Join-Path $projectRoot 'setup_cli.py') configure `
  --config (Join-Path $projectRoot 'config.local.json') `
  --backend codex --model '用户确认的模型ID' `
  --first 120 --idle 90 --total 600
```

Claude 使用默认模型的示例：

```powershell
& $pythonExe -B (Join-Path $projectRoot 'setup_cli.py') configure `
  --config (Join-Path $projectRoot 'config.local.json') `
  --backend claude --first 120 --idle 90 --total 600
```

手动指定安装位置时增加 `--agent 'C:\实际位置\agent.exe'`；JS 入口使用 `--agent 'C:\实际位置\cli.js' --node 'C:\实际位置\node.exe'`。
DSH 使用 `--backend deepseek_harness --model '用户确认的模型ID'`，按需指定路径。
命令参数采用独立字符串传入，不能拼接成待执行的 shell 表达式；所有含空格路径应正确引用。

已有配置且用户授权更新时增加 `--overwrite`。脚本会备份到配置旁的 `output/setup-backups/`，保留未知字段和各后端模型记录，再写入新值。
注意：`configure` 未显式传入的等待时间采用 120/90/600；更新时应传入用户希望保留的等待值。`python_executable` 会记录运行配置脚本的 Python。
不要启动多个配置写入进程。新文件采用完整临时文件发布；已有文件替换前检测变化，但没有跨进程事务锁。

成功报告应为 `ok:true, stage:"configured", model_called:false`。记录配置路径和备份路径，不输出凭据。

## 第四步：验证安装，再按授权验证模型

```powershell
& $pythonExe -B (Join-Path $projectRoot 'setup_cli.py') check `
  --config (Join-Path $projectRoot 'config.local.json')
```

这只证明 Python 和 Agent 程序能启动，不证明登录、额度、模型权限或网络正常。
若是复用旧配置，真实连接测试前将 `$pythonExe` 设为该配置的 `python_executable`，确保测试与 MATLAB 后端使用同一解释器。
用户授权后才执行：

```powershell
& $pythonExe -B (Join-Path $projectRoot 'setup_cli.py') check `
  --config (Join-Path $projectRoot 'config.local.json') --live
```

真实测试只发送固定 `disp(1)` 示例，遵循配置等待时间，不读取编辑器代码。成功必须同时满足 `ok:true, stage:"model_checked", model_called:true`。
失败时区分：配置/程序路径、CLI 协议版本、认证、网络/服务、模型权限或等待超时。报告实际失败，不自动切换付费服务，不反复调用模型碰运气。
界面的模型测试可直接取消；若从终端中止 CLI 检查，只清理该次检查拥有的进程，切勿杀死系统中全部 Python/Agent/MATLAB 进程。

## 第五步：MATLAB 启动与验收

在用户 MATLAB 中运行（替换实际路径）：

```matlab
run('D:/projects/matlab-ai-bridge/start_ai.m')
```

也可让用户全程通过首次配置向导操作，步骤见 [安装与使用](docs/安装与使用.md)。
已有助手窗口需关闭后重开，才能加载外部更新的配置。不要修改用户未保存的编辑器内容来验证安装。
如果无法访问 MATLAB GUI，应明确“命令行检查通过，MATLAB 窗口尚未验证”，不能声称全部完成。
代码生成验证须由用户发起或授权；查看预览通过后才能应用，项目不会自动保存或运行生成代码。

向用户交付：

1. 配置文件与备份的位置。
2. Python、所选 Agent 的路径和检测版本，以及模型 ID、等待时间。
3. 已完成的验证阶段和实际结果；没有调用模型时明确说明。
4. MATLAB 启动命令，以及尚需用户完成的登录/授权/GUI 验证。

不要提交或发布 `config.local.json`、`output/`、临时配置文件；手动 ZIP 打包也需排除。

## 可以直接交给自己的 AI 的提示词

> 请帮我配置本机的 MATLAB AI 助手项目。项目路径是【填写项目绝对路径】，我希望运行时使用【Codex / Claude Code / DeepSeek Harness】，模型是【模型 ID；Claude 可用默认】。先阅读项目根目录的 AI_SETUP.md 和 docs/安装与使用.md，确认我的环境并通过 setup_cli.py 检测、生成或修正配置，保留原配置备份。可以执行不调用模型的安装检查；真实模型测试需要先告诉我会产生用量并征得授权。不要打印密钥或修改 MATLAB 未保存的文档。完成后给我启动方法、实际验证结果和仍需我处理的事项。
