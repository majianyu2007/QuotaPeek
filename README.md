# QuotaPeek

macOS 菜单栏上的额度查看器，读取 VM2API（或 Claude 兼容）的 `/v1/usage`，显示 5 小时和 7 天窗口的用量。SwiftUI + AppKit，没有第三方依赖，需要 macOS 14 以上。

## 安装

打开 `dist/QuotaPeek.dmg`，把 QuotaPeek 拖进「应用程序」。

App 只做了 ad-hoc 签名，没有经过 Apple 公证。第一次打开如果被拦，去「系统设置 → 隐私与安全性」点「仍要打开」。

## 使用

1. 第一次启动会弹出设置窗口。填 API 地址和分发 Key，点「验证并保存」。
2. 之后点菜单栏图标看额度；右键可以切换槽位、刷新、打开设置。

API 地址填服务根地址、`/v1` 或完整的 `/v1/usage` 都行，带反向代理前缀也可以。保存前会真实请求一次，失败就不保存，原来的配置不动。

可以添加多个槽位（每个槽位一组地址 + Key）。菜单栏显示当前槽位，或者所有槽位里最紧张的那个。

## 设置项

- 刷新间隔：1 / 2 / 5 / 15 / 30 分钟，默认 5 分钟。睡眠时不刷新，唤醒后立即刷一次。
- 显示剩余或已用百分比。
- 外观：跟随系统 / 浅色 / 深色。
- 额度提醒：默认关闭，打开后用量超过阈值时发系统通知。
- 登录时启动。

## 行为说明

- 刷新失败时保留上一次的数据，并标成「已过期」。不会把拿不到的值显示成 0。
- 过了重置时间但还没拿到新数据时，也不会自己把用量清零。
- 「查询时间」是本机读到数据的时间，不是服务端采样时间。
- 历史数据只在内存里，重启后重新查询。

## 接口要求

只发一个请求：`GET /v1/usage`，带 `Authorization: Bearer <key>`。

能识别的响应：

```json
{
  "unit": "percent_used",
  "five_hour": { "utilization": 17, "resets_at": "2026-10-16T03:20:00Z" },
  "seven_day": { "utilization": 59, "resets_at": 1792436400 }
}
```

- 也可以包在 `data` 里。另外支持 `seven_day_sonnet`、`seven_day_opus`。
- `utilization` 必须是 0–100 的数字；`null` 或缺失表示未知，不当成 0。
- `resets_at` 可以是 ISO 8601，也可以是 Unix 秒（数字或数字字符串）。
- 其他格式（比如 sub2api 的金额配额、new-api 的钱包余额）不支持，会直接报错，不去猜。

VM2API 返回的是调度到的那个账号的额度，不是这个 Key 自己用了多少。想看指定槽位（比如 vm-01），需要在服务端把 Key 限定到这个槽位。

## 常见错误

| 提示 | 原因 |
| --- | --- |
| 认证失败（401 invalid_api_key） | Key 填错或已被删除 |
| 无权读取用量（403 key_group_mismatch） | Key 的分组和槽位平台不一致 |
| 服务端出错（503 pool_unavailable） | 服务端找不到这个 Key 能用的账号，见下文 |
| 未找到用量接口（404） | 地址或路径前缀不对 |

错误后面括号里的代码直接来自服务端的 `error.code`，方便对照服务端日志。

### 503 pool_unavailable

VM2API 在 `/v1/usage` 这条路由上没有把 Key 的主人角色传给调度器。结果是：只要 Key 绑定了某个用户（哪怕是管理员），调度器就只会去找这个用户自己拥有的槽位。平台槽位（没有 owner 的 vm-01、vm-02）全被排除，于是返回 503。发消息的路由没有这个问题，所以同一个 Key 能正常用模型，只有查额度失败。

不改服务端代码的解决办法：在面板里把这个 Key 的「所属用户」清空，或者在数据库里执行：

```sql
UPDATE api_keys SET user_id = NULL WHERE id = '<key id>';
```

改完立即生效，不用重启。没有 owner 的 Key 走平台范围，和管理员 Key 的权限相同；代价是这个 Key 的用量不再记到该用户名下。

## 安全

- Key 存在本机钥匙串，不随 iCloud 同步。其余配置在 `~/Library/Application Support/QuotaPeek/preferences.json`，权限 0600。
- 只允许 HTTPS；`localhost`、`127.0.0.1`、`::1` 可以用 HTTP 调试。
- 遇到重定向直接报错，不会带着 Key 跳到别的地址。
- 不保存响应原文，不读浏览器 Cookie，不发模型请求。响应超过 1 MiB 就停止读取。
- 错误提示只显示固定文案和服务端的短错误码，不显示服务端返回的原始文本。

## 开发

需要完整的 Xcode（跑测试要 XCTest）。如果 `xcode-select` 指向的是 Command Line Tools，在命令前加上 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`。

```sh
swift test                                  # 单元测试
swift test --filter QuotaCoreTests.testUnixSecondResetTimes   # 单个测试
bash scripts/build-app.sh                   # 打包到 dist/（本机架构）
bash scripts/build-app.sh --universal       # arm64 + x86_64
```

正式分发要用自己的 Developer ID：`IDENTITY="Developer ID Application: ..." bash scripts/build-app.sh`。脚本不做公证。

命令行工具和 App 用的是同一套解析和请求代码，方便排查：

```sh
swift run quota-peek --parse response.json
swift run quota-peek --base-url https://api.example.com --key-stdin   # Key 从标准输入读，不进 shell 历史
```

代码结构：

- `Sources/QuotaCore`：URL 规范化、请求、响应解析、配置格式
- `Sources/QuotaPeek`：App（菜单栏、界面、刷新调度、钥匙串和配置存储）
- `Sources/QuotaPeekCLI`：命令行工具
- `Tests/QuotaCoreTests`：`QuotaCore` 的测试

额度卡片和倒计时的布局参考了 [ClaudeBar](https://github.com/tddworks/ClaudeBar)，代码和图标是自己写的。
