# QuotaPeek

QuotaPeek 是一个 macOS 菜单栏应用，用于查看 VM2API 及 Claude 兼容接口（`GET /v1/usage`）返回的 5 小时与 7 天用量。基于 SwiftUI 与 AppKit 实现，无第三方依赖，支持 macOS 14 及以上版本。

## 安装

从 [Releases](https://github.com/majianyu2007/QuotaPeek/releases) 下载 `QuotaPeek.dmg`，将 QuotaPeek 拖入「应用程序」。

应用仅使用 ad-hoc 签名，未经 Apple 公证。首次打开时，系统可能提示“Apple 无法验证 QuotaPeek 是否包含可能危害 Mac 安全或泄漏隐私的恶意软件”。可选择以下任一方式处理：

- 点击「完成」，然后在「系统设置 → 隐私与安全性」中选择「仍要打开」。
- 在终端中移除隔离属性后重新打开：

  ```sh
  xattr -dr com.apple.quarantine /Applications/QuotaPeek.app
  ```

覆盖安装新版本后，首次读取钥匙串时系统可能请求授权，选择「始终允许」即可。

## 使用

1. 首次启动时会打开设置窗口。填写 API 地址与 API Key，点击「验证并保存」。
2. 点击菜单栏图标查看用量；右键菜单可切换槽位、刷新或打开设置。

API 地址可填写服务根地址、`/v1` 或完整的 `/v1/usage`，支持反向代理路径前缀。保存前会实际请求一次接口，验证失败时不会修改已有配置。

每个槽位对应一组 API 地址与 Key，可添加多个。菜单栏可显示当前选中的槽位，或所有槽位中剩余额度最少的一个。

## 设置

| 设置项 | 说明 |
| --- | --- |
| 刷新间隔 | 1、2、5、15、30 分钟，默认 5 分钟；睡眠期间暂停，唤醒后立即刷新 |
| 显示方式 | 剩余百分比或已用百分比 |
| 外观 | 跟随系统、浅色、深色 |
| 额度提醒 | 默认关闭；开启后，用量超过阈值时发送系统通知 |
| 登录时启动 | 默认关闭 |

## 数据显示规则

- 刷新失败时保留上一次成功获取的数据，并标记为「已过期」。
- 接口未返回的用量显示为未知，不按 0 处理。
- 到达重置时间但尚未获取新数据时，保留原数值，不自动归零。
- 「更新时间」为本机获取数据的时间，不代表服务端的采样时间。
- 用量数据仅保存在内存中，应用重启后重新获取。

## 接口格式

请求为 `GET /v1/usage`，请求头为 `Authorization: Bearer <key>`。响应示例：

```json
{
  "unit": "percent_used",
  "five_hour": { "utilization": 17, "resets_at": "2026-10-16T03:20:00Z" },
  "seven_day": { "utilization": 59, "resets_at": 1792436400 }
}
```

| 字段 | 要求 |
| --- | --- |
| `five_hour`、`seven_day` | 用量窗口；另支持 `seven_day_sonnet`、`seven_day_opus` |
| `utilization` | 0–100 的数值；为 `null` 或缺失时视为未知 |
| `resets_at` | 可选；ISO 8601 字符串或 Unix 时间戳（秒） |
| `unit` | 可选；如提供，必须为 `percent_used` |

响应也可整体包装在 `data` 字段中。不符合上述格式的响应会提示格式不受支持。

请求失败时，界面显示 HTTP 状态码及服务端返回的错误码（如 `401 invalid_api_key`）。

## 安全

- API Key 保存在本机钥匙串中，不参与 iCloud 同步。其他配置保存在 `~/Library/Application Support/QuotaPeek/preferences.json`，文件权限为 0600。
- 仅允许 HTTPS 地址；`localhost`、`127.0.0.1` 与 `::1` 允许使用 HTTP，便于本地调试。
- 拒绝跟随重定向，避免 API Key 被发送到其他地址。
- 不保存响应内容，不读取浏览器 Cookie，响应超过 1 MiB 时停止读取。

## 开发

运行测试需要完整安装 Xcode。若当前选中的是 Command Line Tools，请通过 `DEVELOPER_DIR` 指定 Xcode 路径。

```sh
swift test                                # 运行全部测试
swift test --filter QuotaCoreTests.<名称>  # 运行单个测试
bash scripts/build-app.sh                 # 构建当前架构，输出到 dist/
bash scripts/build-app.sh --universal     # 构建 arm64 + x86_64 通用版本
```

如需使用 Developer ID 签名，设置 `IDENTITY` 环境变量：`IDENTITY="Developer ID Application: ..." bash scripts/build-app.sh`。构建脚本不包含公证步骤。

命令行工具 `quota-peek` 与应用共用请求和解析代码：

```sh
swift run quota-peek --parse response.json
swift run quota-peek --base-url https://api.example.com --key-stdin
```

| 目录 | 内容 |
| --- | --- |
| `Sources/QuotaCore` | 地址规范化、网络请求、响应解析、配置格式 |
| `Sources/QuotaPeek` | 应用界面、刷新调度、钥匙串与配置存储 |
| `Sources/QuotaPeekCLI` | 命令行工具 |
| `Tests/QuotaCoreTests` | 单元测试 |

## 致谢

额度卡片与倒计时的界面布局参考了 [ClaudeBar](https://github.com/tddworks/ClaudeBar)。
