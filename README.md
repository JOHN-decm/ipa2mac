# ipa-mac

在 Apple Silicon Mac 上侧载已解密的 iOS IPA。这个工具受 PlayCover 启发，将 IPA 中的可执行文件转换为 Mac Catalyst 平台并重新签名。窗口由 macOS 原生管理，无需注入 PlayTools。[PlayCover 项目](https://github.com/PlayCover/PlayCover)

## 环境要求

- 使用 Apple Silicon 芯片的 Mac。
- 安装 Xcode 命令行工具。系统未安装时，运行 `xcode-select --install`。
- 准备一个已解密、包含 `arm64` 可执行文件的 `.ipa`。

## 图形界面

在项目目录运行以下命令，生成 `dist/IPA装到Mac.app` 和可分发的 `dist/IPA装到Mac.zip`。

```sh
./build.sh
```

将 `.ipa` 拖到 `IPA装到Mac.app` 图标上，或双击应用后选择文件。工具会安装并尝试启动目标应用，然后显示结果。

## 命令行

```sh
./ipa2mac.sh "示例.ipa"                              # 安装后尝试启动
./ipa2mac.sh --no-launch "示例.ipa"                  # 只安装
mkdir -p "$HOME/Applications"
./ipa2mac.sh --dest "$HOME/Applications" "示例.ipa"  # 安装到已有的自定义目录
```

默认安装到 `/Applications`。安装会覆盖目标目录里的同名 `.app`。卸载时，删除安装生成的 `.app` 即可。

## 工作原理和限制

工具在临时目录解包，检查 FairPlay 加密，修改 Mach-O 平台，再由内向外执行临时签名（ad-hoc signing）。原始 IPA 保持不变。

- 工具处理已解密的 IPA，遇到仍受 FairPlay 加密的应用会报错。
- 重新签名后，依赖原签名权限的功能可能失效，例如钥匙串、App Group、推送和 iCloud。有防篡改检测的应用也可能无法启动。
- 图形界面产物使用 ad-hoc 签名。下载到其他 Mac 后，是否能直接打开取决于系统的 Gatekeeper 设置。

## 项目结构

| 路径 | 用途 |
| --- | --- |
| `ipa2mac.sh` | IPA 转换、签名与安装，也是命令行入口 |
| `app/main.applescript` | 图形界面的选取文件和拖放逻辑 |
| `build.sh` | 从源码构建并签名 `.app`，生成 ZIP |
| `dist/` | 本地构建产物，由 Git 忽略 |

修改脚本后，重新运行 `./build.sh`，图形界面会打包最新的命令行脚本。
