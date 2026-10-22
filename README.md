# 米家菜单栏 · MijiaMenuBar

> **第三方工具，非小米官方。** 本项目与小米、米家及日立没有任何关联，仅通过米家云端接口读取和控制你自己账号下的设备。

在 macOS 菜单栏按房间控制家里的米家设备：空调、灯与灯组、窗帘、插座、循环扇、空气净化器、浴霸、净烟机，并查看电饭煲状态。支持自定义场景、定时关闭、漏水提醒、快捷指令和浅色 / 深色模式。每台 Mac 独立扫码登录，可以跨网络使用，无需 Home Assistant、Tailscale 或家中 Mac 常开。

<img src="docs/images/control-glass.png" alt="早期版本的空调控制面板，演示房间" width="360">

截图为 v0.3.4 的空调控制视图（演示数据），早于 v0.5 起新增的全屋设备、场景和新版面，仅供参考。

## 下载与安装

要求 **macOS 13 或更新版本**。

| Mac 类型 | 下载 |
| --- | --- |
| Apple Silicon（M 系列） | [arm64.zip](https://github.com/VUVUDOG/MijiaMenuBar/releases/download/v0.8.1/MijiaMenuBar-0.8.1-arm64.zip) |
| Intel 处理器 | [intel.zip](https://github.com/VUVUDOG/MijiaMenuBar/releases/download/v0.8.1/MijiaMenuBar-0.8.1-intel.zip) |

[全部版本](https://github.com/VUVUDOG/MijiaMenuBar/releases) · [安装使用说明](docs/usage.md)

1. 确认手机米家 App 能正常控制要使用的设备。日立中央空调需先在米家 → 连接三方平台 → 日立中央空调中完成关联。
2. 下载匹配芯片的 ZIP，解压后将 `MijiaMenuBar.app` 放入「应用程序」并打开。
3. 点击菜单栏「米家」，选择「扫码登录米家」，用米家 App 扫码并在手机确认。
4. 等待房间和设备载入，选择房间进行控制。

安装包包含运行环境，无需安装 Python、uv 或开发工具。每台 Mac 各自登录。

应用内更新：启动时及每 24 小时检查新版本，面板出现「发现新版本」后点击「更新」即可自动下载、校验、替换并重新打开。由于使用 ad-hoc 签名，**每次更新后 macOS 会再要求一次钥匙串授权**，输入登录密码并选「始终允许」即可。**v0.5.1 起应用文件改名为 `MijiaMenuBar.app`，旧版「日立空调」（`HitachiMenuBar.app`）无法自动更新到本版本：请手动下载一次，退出并删除旧应用后打开新版**，登录状态会保留。

## 功能

**按房间浏览**：房间排成一行，点击切换，面板打开时也可用 ← / → 键切换；有设备开着的房间右上角显示绿点，悬停显示室温。只读取空调所在的米家家庭，其他家庭（如公司、亲友共享）的设备不会出现。

**空调**：一行显示状态、设定温度（整数度）和开关，点击展开模式、风量与定时；显示同房间米家温湿度计的室温和湿度。

**设备**（双列方块：单击开关，点右侧滑杆图标展开调节，右键加入「常用」；按住拖动可调整顺序，每个房间独立记忆）：

| 设备 | 可调项 |
| --- | --- |
| 灯 / 米家灯组 | 开关、亮度、色温；灯组排在最前，可一键控制整组 |
| 窗帘 | 打开 / 暂停 / 关闭、开合百分比，显示当前位置 |
| 插座 | 开关，显示实时功率 |
| 循环扇 | 开关、直吹 / 自然风、风速档位、摇头 |
| 空气净化器 | 开关、模式、风速，显示 PM2.5 |
| 浴霸 | 照明（开关、亮度、色温）、模式、换气开关与档位、目标温度 |
| 净烟机 | 开关、风速、照明、净化，显示 PM2.5 |
| 电饭煲 | 选择烹饪模式并开始（需二次确认）、停止；口感、保温时间、目标时间、自动熄屏；显示状态与剩余时间 |

为避免给智能灯断电，**墙壁开关不接入**；门锁、摄像机、保管箱等安全类设备不接入。

**场景、常用与批量操作**

- **自定义场景**：齿轮菜单「新建场景…」，为场景起名，添加设备或「录制开着的设备」，每个设备一行，可切换开 / 关。点场景按钮执行，**再点一下关闭**场景打开的设备。场景保存在本机，不写入米家账号。
- **常用**：右键设备加入，面板顶部直接开关，不用切换房间。
- **一键全关**：全屋或单个房间，关闭灯、风扇、净化器、浴霸、净烟机和空调；不含插座、窗帘和电饭煲。
- **定时关闭**：空调、灯、风扇、净化器、浴霸、净烟机、插座可设 1 / 2 / 4 小时后关闭，显示倒计时；由本应用计时，需 Mac 开着。
- **漏水提醒**：厨房阳台等水浸传感器检测到漏水时，发系统通知、菜单栏显示「漏水」，每 30 分钟重复提醒；面板收起时每分钟后台检查。
- **快捷指令**：「开关米家设备」「关闭房间」「设置空调温度」，可配合 Siri 或自动化使用。

**操作体验**

- 点击即生效：界面立即显示新状态，后台并行同步，同一设备的多项改动合并发送；云端回读未确认时自动恢复原状态并点名提示。
- 展开面板立即刷新，之后每 30 秒刷新；设备只读取当前房间，切换房间时刷新。
- 外观：齿轮菜单「外观」可选跟随系统、浅色或深色；macOS 26+ 使用原生 Liquid Glass，macOS 13–15 回退到菜单毛玻璃。
- 登录过期时直接提示并弹出扫码入口。
- 齿轮菜单：新建场景、同步房间、重新登录、退出登录、外观、开机自动启动、检查更新、复制诊断、退出应用。
- 登录会话保存在本机系统钥匙串；本次运行的后续请求复用内存会话。

新增或更换设备、调整米家房间后，在齿轮菜单点击「同步房间」即可重新识别。

## 当前说明

**第三方工具，非小米官方产品**，与小米、米家及日立无关。功能依赖米家云端服务，接口变化可能导致暂时不可用；各设备功能以其米家功能定义为准，尚未验证全部型号。

当前使用 ad-hoc 开发签名，未取得 Developer ID 签名或 Apple 公证。首次启动如提示无法验证开发者，确认下载来源后可在「系统设置 → 隐私与安全性」允许打开。

钥匙串弹窗需要当前 Mac 的「登录」钥匙串密码。选择「始终允许」可记住对当前程序的授权；更新版本可能触发重新授权。

Intel 版已通过 Apple Silicon 主机上的 Rosetta 验证，尚未在实体 Intel Mac 上实测。

## 源码构建

开发需要 macOS、Xcode 26 或更新版本（包含 macOS 26+ SDK，打包时用它生成快捷指令的动作说明）和 [uv](https://docs.astral.sh/uv/)。

Apple Silicon：

```sh
uv sync --frozen --python 3.12
uv run python build.py --worker
```

输出 `dist/MijiaMenuBar.app`。仅修改 Swift 界面后可运行 `uv run python build.py`；云端代码变更后需要 `--worker`。

在 Apple Silicon 主机上构建 Intel 版，需要 Rosetta 和独立的 x86_64 Python：

```sh
uv python install cpython-3.12.13-macos-x86_64-none
UV_PROJECT_ENVIRONMENT=.venv-intel uv sync --frozen --python cpython-3.12.13-macos-x86_64-none
.venv-intel/bin/python build.py --arch x86_64 --worker
```

输出 `dist/intel/MijiaMenuBar.app`。必须使用与目标架构对应的 Python 构建。

## 验证与反馈

```sh
uv run python -m unittest -v
uv run python verify_app.py
.venv-intel/bin/python verify_app.py --arch x86_64
uv run python verify_packages.py
```

单元测试与原生回归使用临时目录、模拟钥匙串和模拟会话，不控制真实设备；设备列表的布局测试使用 `docs/fixtures/accessories.json` 中匿名化的设备功能定义。打包检查要求两种架构已构建。

`verify_control.py` 是真实设备集成检查，会调节指定关机房间的空调设定温度并恢复，仅在需要真实设备验证时手动运行。

运行数据位于 `~/Library/Application Support/HitachiMenuBar`（沿用旧目录以保留登录）；开发脚本默认使用 `.runtime/`。这些文件及凭证不属于源码或发行包。

请在 [Issues](https://github.com/VUVUDOG/MijiaMenuBar/issues) 提供版本、Mac 芯片、macOS 版本、复现步骤及「齿轮 → 复制诊断信息」。诊断不含账号、密码、设备标识或登录会话；不要提交实时二维码或设备报告。

## 开源许可

本项目采用 [MIT License](LICENSE) 开源，版权署名为 **Copyright (c) 2026 GT**。

允许使用、复制、修改、分发及商用，包括发布修改后的版本；分发本软件或其重要部分时，须保留版权声明和 MIT 许可声明。软件按许可证中的“原样”条款提供。

「小米」「米家」为其权利人的商标，本项目仅用于说明兼容性，不代表任何授权或合作关系。第三方依赖及引用代码仍遵循各自的许可证。欢迎通过 [Issues](https://github.com/VUVUDOG/MijiaMenuBar/issues) 反馈问题，或提交 Pull Request 参与改进。

## 实现参考

- [hass-xiaomi-miot](https://github.com/al-one/hass-xiaomi-miot)：设备列表和 MIoT 云端请求。
- [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)：米家扫码协议。
- [日立智家关联米家社区讨论](https://bbs.hassbian.com/archiver/?tid-28735.html)。
