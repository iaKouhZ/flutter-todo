# 待办清单

Todo Endfield 的 Flutter Android / Windows 客户端。界面使用原项目的奶油纸底、墨黑文字和信号黄，功能包括追踪、规划、已完成、全部、分类筛选、搜索与任务详情。

1. 在 [GitHub Actions](https://github.com/iaKouhZ/flutter-todo/actions/workflows/android.yml) 打开一次已签名的成功运行，从 Artifacts 直接下载 `flutter-todo.apk` 后安装。首批调试签名 APK 与正式签名不同，切换时需先卸载调试版。
2. 首次打开填写原站的根地址，例如 `https://example.com/todo/`。客户端支持根目录与子目录部署，也支持原项目的两种 URL 模式。
3. 允许访客访问时直接进入首页。新增、编辑、删除、勾选、追踪、置顶或修改子任务时需要密码。关闭访客访问的服务器会先显示登录界面。密码使用 Android Keystore 加密保存。
4. 在桌面长按空白处，从小组件列表添加 **最近到期**（4×2）。它支持上下滚动查看完整列表，拖动边缘可调整宽高。显示行数随高度增加，包含网页「追踪中」里符合近 X 天范围的子任务。每组先显示主任务，再按截止日期和时刻显示子任务。标题在左、日期在右，有具体时刻时分两行显示日期和时刻。优先显示即将到期的组，有空位时补入最近逾期的事项。系统按约 30 分钟调度，打开应用或修改任务也会请求同步。小组件使用圆角并跟随系统深浅模式。桌面可直接看到任务标题。

## 编辑截止时间与完成时间

- 在详情页添加子任务时，可选填截止日期和时刻。修改已有子任务的截止时间，进入主任务的编辑页，在「子任务截止时间」中点选对应条目并保存。
- 在已完成事项的详情页点「编辑完成时间」。对于重复待办，从对应的已完成日期进入详情，会修改那一次的完成时间。填写的日期和时刻使用服务器时区。

「追踪中」列表与网页一致，按服务器的近 X 天范围，在母任务下显示追踪中且未完成的子任务。

## 与服务器的交互

客户端使用原项目的 `index.php`、`login.php`、`admin.php` 和任务操作表单。它识别追踪页和登录页的 HTML，按服务器生成的地址提交写操作，并携带 Cookie、CSRF 字段和 AJAX 标记。因此现有部署可直接接入；升级服务端主题或页面结构时，需要同步检查客户端选择器。登录与任务编辑沿用站点配置和权限。应用支持明确输入 `http://` 的局域网站点，公开部署请使用 HTTPS。课程表导入与全局系统设置仍在网页后台管理。

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
- 服务器和设置保存在 `%LOCALAPPDATA%\TodoEndfield\settings.dat`。服务器密码由 Windows DPAPI 按当前用户加密。
- 安装器关闭了卸载注册项。卸载入口在开始菜单的「卸载待办清单」或安装目录中的 `unins000.exe`，卸载会移除本应用的自启动快捷方式，保留个人配置文件。

Windows runner 源码和安装脚本包含注册表写入检查，安装验证检查卸载注册项。构建会检查 PE 架构，测试密码加密、快捷方式和置顶，执行安装、启动与卸载检查。Windows 构建使用 Flutter 3.44.0。

### Actions 触发范围

| 修改范围 | 自动执行 |
| --- | --- |
| `platform/android/`、Android 准备/签名脚本 | Android APK |
| `platform/windows/`、Windows 准备/打包/验证脚本 | Windows installers |
| `lib/`、`test/`、`pubspec.yaml` | Shared Dart checks（静态分析与测试） |

共享代码修改通过检查后，在对应平台的工作流页面选择 **Run workflow** 生成安装包。Windows 可选择 `all`、`x64` 或 `arm64`。
