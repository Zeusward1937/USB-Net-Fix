# UsbNetFix

**让 Windows 不再每插一次手机就多一个「网络 2」「网络 3」……**

安卓手机开 USB 网络共享时，Windows 会认为连上了一个全新网络，于是新建一个配置文件、名字顺延。插几次就多几个「网络 N」。网上常见的建议是「网络重置」——那会把你**所有保存的 WiFi 全部清空**，代价太大。

UsbNetFix 会在 Windows 刚建好配置文件的那一刻把它**改名成手机的名字**（如 `Pixel 8`、`小米 14`），并清掉那台手机自己留下的旧配置。

```
改之前                              改之后
  网络           2026-10-09            Pixel 8        专用   ← 你的手机
  网络 2         2026-10-11            HomeWiFi       公用   ← 从未被动
  网络 3         2026-10-12            OfficeNet      公用   ← 从未被动
  HomeWiFi       2026-03-02
  OfficeNet      2026-04-15
```

- ✅ 你的 WiFi 配置文件**一个都不会丢**，也**永远不会被修改**
- ✅ 多台手机各自独立命名、互不干扰
- ✅ 空闲时**完全不运行**（事件驱动，无轮询、无常驻进程）
- ✅ 纯 PowerShell，不装驱动、不做系统级 hook

---

## 安装

1. 下载或 clone 本仓库
2. **双击 `UsbNetFix.cmd`** → 选 `5` → UAC 点「是」

完成。会注册一个计划任务（开机自启 + 插手机时触发）。

> 需要管理员权限（网络配置数据库在 `HKLM` 下）。
> 想装到专门的目录：`powershell -ExecutionPolicy Bypass -File deploy.ps1`

## 日常使用

**什么都不用做。** 插线、打开 USB 网络共享，几秒后网络名就变成手机的名字。

需要时双击 `UsbNetFix.cmd` 打开控制面板：

| 菜单 | 作用 |
|---|---|
| `1 status` | 看当前状态（设备、网络配置、任务、日志）|
| `2 names` | **看当前手机会被叫什么名字、依据是什么** |
| `3 monitor` | 实时状态 + 手机当前暴露的 USB 模式 |
| `4 apply` | 立刻执行一次修复 |
| `5 install` | 安装 / 修复 |
| `6 diagnose` | 生成诊断快照（反馈问题时用）|
| `7` / `8` | 编辑配置 / 打开日志目录 |
| `9 uninstall` | 卸载 |

命令行也可以：`UsbNetFix.cmd status`、`UsbNetFix.cmd names`、`UsbNetFix.cmd monitor`

## 换手机 / 多台手机

**直接插上就行**，工具按 USB 序列号区分设备，各自独立命名。

| 情况 | 结果 |
|---|---|
| 手机曾用「传输文件」模式连过电脑 | 自动用手机型号命名，如 `Pixel 8` |
| 手机从没连过「传输文件」 | 先用默认名 `USB Tethering`；在手机上把 USB 用途切成「传输文件」一次，型号就记住了 |
| 想固定成自定义名字 | 在 `config.json` 加一条规则（见下）|

```json
"DeviceRules": [
  { "Vid": "18D1", "ModelLike": "^Pixel 8$",   "Name": "我的 Pixel" },
  { "Vid": "2717", "ModelLike": "^Xiaomi 14$", "SerialLike": "^ABC123", "Name": "测试机" }
]
```

- `ModelLike`：匹配手机上报的型号名（`+` 要转义成 `\+`）
- `SerialLike`：匹配 USB 序列号（同型号多台时用它区分）
- 串号怎么查：`UsbNetFix.cmd names`

> ⚠️ **别给两台手机设同样的名字**，同名会被当成彼此的旧残留清理掉。

## 配置（`config.json`）

常用的几个：

| 键 | 默认 | 说明 |
|---|---|---|
| `DeviceRules` | `[]` | 自定义命名规则（见上）|
| `Category` | `Private` | 网络类型：`Private`（专用，可文件共享）/ `Public`（公用）/ `Keep`（不改）|
| `DefaultName` | `USB Tethering` | 读不到型号时用的名字 |
| `SettleSeconds` | `8` | 等 Windows 确定配置后再改名 |
| `ForgetLegacyProfiles` | `true` | 删除该手机自己留下的旧配置 |
| `Verbose` | `false` | 输出详细调试日志 |

## 卸载

```powershell
.\UsbNetFix.cmd uninstall        # 交互式
.\uninstall.ps1 -Purge           # 连程序文件一起删
```

## 已知限制

1. **型号名需要连过一次「传输文件」模式**，否则首次显示默认名。
2. **Windows 底层仍会为每次会话建配置文件**，工具负责改名并清掉该手机的旧残留，所以你看不到列表增长。
3. **无法阻止安卓更换 MAC**（未 root 的手机不允许改），本工具是"接管"而非"阻止"，效果等价。

## 更多文档

| 文档 | 内容 |
|---|---|
| [docs/技术细节.md](docs/技术细节.md) | 根因分析、识别原理、事件驱动架构、资源占用实测 |
| [docs/安全说明.md](docs/安全说明.md) | 安全模型、实测验证记录、回滚方法 |
| [docs/常见问题.md](docs/常见问题.md) | 故障排查、开发踩坑记录 |

## 许可

MIT，见 [LICENSE](LICENSE)。

与 Google、vivo、小米、三星、微软均无关联。本工具只修改 Windows 自己的网络配置数据库，不装驱动、不做系统级 hook。

---

**English**: [README.en.md](README.en.md)
