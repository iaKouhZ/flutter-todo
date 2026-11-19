# 待办清单

Todo Endfield 的 Flutter Android / Windows 客户端。界面使用原项目的奶油纸底、墨黑文字和信号黄，功能包括追踪、规划、已完成、全部、分类筛选、搜索与任务详情。

1. 在 [GitHub Actions](https://github.com/iaKouhZ/flutter-todo/actions/workflows/android.yml) 打开一次已签名的成功运行，从 Artifacts 直接下载 `flutter-todo.apk` 后安装。首批调试签名 APK 与正式签名不同，切换时需先卸载调试版。
2. 首次打开填写原站的根地址，例如 `https://example.com/todo/`。客户端支持根目录与子目录部署，也支持原项目的两种 URL 模式。
3. 允许访客访问时直接进入首页。新增、编辑、删除、勾选、追踪、置顶或修改子任务时需要密码。关闭访客访问的服务器会先显示登录界面。密码使用 Android Keystore 加密保存。
4. 在桌面长按空白处，从小组件列表添加 **最近到期**（4×2）。它支持上下滚动查看完整列表，拖动边缘可调整宽高。显示行数随高度增加，包含网页「追踪中」里符合近 X 天范围的子任务。每组先显示主任务，再按截止日期和时刻显示子任务。标题在左、日期在右，有具体时刻时分两行显示日期和时刻。优先显示即将到期的组，有空位时补入最近逾期的事项。系统按约 30 分钟调度，打开应用或修改任务也会请求同步。小组件使用圆角并跟随系统深浅模式。桌面可直接看到任务标题。

## 编辑截止时间与完成时间

- 在详情页添加子任务时，可选填截止日期和时刻。修改已有子任务的名称或截止时间时，进入主任务的编辑页，点选对应的子任务，修改后保存主任务。主任务已完成时，先恢复为未完成并保存，再修改子任务的名称或截止时间。
- 已完成子任务会显示完成状态和时间。在详情页点对应子任务的「编辑子任务完成时间」，也可在主任务编辑页调整各已完成子任务的完成时间；主任务已完成时仍可编辑子任务完成时间。日期和时刻使用服务器时区，未修改的完成时间会保留原始精度。
- 在已完成事项的详情页点「编辑完成时间」。对于重复待办，从对应的已完成日期进入详情，会修改那一次的完成时间。填写的日期和时刻使用服务器时区。

「追踪中」列表与网页一致，按服务器的近 X 天范围，在母任务下显示追踪中且未完成的子任务。

## 与服务器的交互

客户端使用原项目的 `index.php`、`login.php`、`admin.php` 和任务操作表单。它识别追踪页和登录页的 HTML，按服务器生成的地址提交写操作，并携带 Cookie、CSRF 字段和 AJAX 标记。因此现有部署可直接接入；升级服务端主题或页面结构时，需要同步检查客户端选择器。登录与任务编辑沿用站点配置和权限。应用支持明确输入 `http://` 的局域网站点，公开部署请使用 HTTPS。全局系统设置仍在网页后台管理。

兼容网页版 1.0.1 的登录限流。客户端会提示等待时间并保留已保存的密码。网页端注销全部设备后，已保存口令的客户端仍可自动恢复会话。备份与恢复继续在网页后台维护页操作。

## 构建

GitHub Actions 使用 Flutter 3.38.9，在 runner 上生成 Android 工程骨架并叠加仓库的 Android 平台文件，然后运行静态分析、协议测试和 APK 构建。签名步骤使用固定的 Android 发布密钥并核对 APK 的证书指纹。签名后的 APK 以原始文件保存在该次运行的 Artifacts 中。

### 配置自定义签名

可以用自己的 Android 签名密钥构建 APK。要覆盖安装已有版本，请沿用该版本的签名密钥。

#### 1. 准备签名密钥库

使用 JDK 的 `keytool` 生成自己的 PKCS#12 密钥库。命令会交互式询问密码和证书信息。

```bash
keytool -genkeypair -keystore android-release.p12 -storetype PKCS12 -alias todo-release -keyalg RSA -keysize 3072 -validity 10958
```

已有密钥库也可以复用。当前签名脚本需要 PKCS#12 格式、`todo-release` 别名，以及相同的密钥库密码和私钥条目密码。请保留密钥库和密码的私有备份。

#### 2. 添加仓库 Secrets

在你要构建的仓库打开 **Settings → Secrets and variables → Actions → New repository secret**，添加以下两项。

| Secret | 值 |
| --- | --- |
| `ANDROID_KEYSTORE_B64` | `android-release.p12` 文件的单行 Base64 |
| `ANDROID_KEYSTORE_PASSWORD` | 生成密钥库时设置的密码 |

根据系统选择一条命令来转换密钥库：

```bash
# Linux / macOS
base64 < android-release.p12 | tr -d '\r\n'
```

```powershell
# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path '.\android-release.p12').Path)) | Set-Clipboard
```

Base64 可还原成原始密钥库文件。请把它和密码填进 Secrets，保存在自己的备份中。

#### 3. 构建并下载 APK

在 **Actions → Android APK → Run workflow** 中选择 `main`。构建完成后，在该次运行的 **Artifacts** 区域直接下载 `flutter-todo.apk`。配置 Secrets 后，推送相关改动到 `main` 也会触发签名构建。

## Windows 电脑版

在 Actions 的 **Windows installers** 中选择成功的运行，直接下载对应的安装程序。

| 系统 | 文件 |
| --- | --- |
| Windows 10 1809 及以上 / Windows 11 x64 | `flutter-todo-windows-x64-setup.exe` |
| Windows 11 ARM64 | `flutter-todo-windows-arm64-setup.exe` |

安装默认位于当前用户的 `%LOCALAPPDATA%\Programs\TodoEndfield`，可选择其他目录。右上角的齿轮打开「电脑版设置」。

- 自启动开关在当前用户的 `shell:startup` 中创建或删除 `TodoEndfield.lnk`，默认关闭。
- 窗口置顶立即生效，应用重启后恢复上次设置，默认关闭。
- 正常关闭应用、关机或注销时保存窗口大小、位置和最大化状态，下次打开自动恢复。最小化关闭时恢复到最小化前的普通或最大化状态，不会以最小化状态启动。窗口状态单独保存在 `%LOCALAPPDATA%\TodoEndfield\window.dat`，不修改注册表；移动、缩放时不持续写入。强制结束、崩溃或断电不保证保存本次布局。
- 服务器和设置保存在 `%LOCALAPPDATA%\TodoEndfield\settings.dat`。服务器密码由 Windows DPAPI 按当前用户加密。
- 安装器在当前用户下注册 Windows 卸载项，可从「已安装的应用」、开始菜单或安装目录中的 `unins000.exe` 卸载。卸载会删除本应用的卸载注册项和自启动快捷方式，保留个人配置文件。

Windows runner 源码包含注册表写入检查。安装器只使用当前用户的标准卸载注册项，自动化验证检查安装时注册、卸载后删除。构建会检查 PE 架构，测试密码加密、快捷方式和置顶，执行安装、启动与卸载检查。Windows 构建使用 Flutter 3.47.5，包含 Dart 的失败证书回调返回站点证书的修正；不要退回使用会向回调返回签发者证书的旧 SDK。

Windows 遇到 Dart 无法建立的 HTTPS 信任链时，会使用随应用打包的 `ledger_tls.exe` 调用 Windows 原生 SSL 证书链策略，允许系统按需补全证书链。它验证服务器域名、证书有效期、服务端用途与可信签发链；验证失败仍拒绝连接，不提供忽略证书错误的开关。应用不会自行安装根证书或修改证书注册表。\n\n连接失败时，客户端会显示底层网络或证书错误。开发者也可运行 `todo_endfield.exe --check-server <站点地址> <结果文件路径>`，使用已编译程序只读检查服务器连接，结果以 JSON 保存。使用 `--check-server-windows-trust` 可强制测试 Windows 原生证书验证路径。

### Actions 触发范围

| 修改范围 | 自动执行 |
| --- | --- |
| `platform/android/`、Android 准备/签名脚本 | Android APK |
| `platform/windows/`、Windows 准备/打包/验证脚本 | Windows installers |
| `lib/`、`test/`、`pubspec.yaml` | Shared Dart checks（静态分析与测试） |

共享代码修改通过检查后，在对应平台的工作流页面选择 **Run workflow** 生成安装包。Windows 可选择 `all`、`x64` 或 `arm64`。可在 `server_probe` 中选填自己的站点地址，额外执行协议连接和安装后 EXE 的只读连接检查；默认留空，构建不依赖某个固定站点。

## 服务端功能同步

客户端沿用服务端的任务表单，包括子任务名称和截止时间编辑。

| 提交 | 服务端变化 | 客户端对应行为 |
| --- | --- | --- |
| `75a5e9c` | 后台任务表单支持子任务编辑 | 编辑主任务时可修改子任务名称 |
| `a50abd9` | 子任务截止时间、主任务完成时间编辑 | 已支持，继续兼容 |
| `8b6db80` | 追踪列表显示远期事项 | 按服务器分段和顺序显示「未设截止日与远期」 |
| `f367143` | 子任务完成时间、按时/逾期完成状态 | 详情和编辑页支持修改已完成子任务的时间 |
| `3750e71` | 移除课程表功能 | 移除课程表专用提示，保留通用只读字段识别 |
| `4be94f7` | 倒计时曾改为向上取整 | 采用后续提交的最新规则 |
| `3c50ea8` | 倒计时向下取整到小时 | 沿用服务端「不到1小时」「X小时后」「X天X小时后」文案 |

未设置截止时刻时，服务端按当日 23:59 计算。应用直接显示服务器给出的倒计时及完成状态，不使用手机或电脑的本地时区重算。安卓小组件兼容新文案和旧版 `T+X` 文案，继续显示绝对截止日期、时刻，并正确处理跨年和闰日；子任务范围仍由服务端近 X 天列表决定。
