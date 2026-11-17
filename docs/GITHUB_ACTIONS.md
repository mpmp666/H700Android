# GitHub Actions 构建尝试

本分支新增 `.github/workflows/h700-cloud-build.yml`。这套入口调用已有公共构建工具，不改变产品源码、源码清单或 H700 启动组件。

## 首次运行

推送 `codex/github-actions-h700` 分支会运行源码清单验证、11项公共工具测试和导航核心 Java 实际编译/回归测试，并上传小型验证报告。运行摘要同时列出运行器实际空闲空间和两个外部输入地址是否已配置。这一步不会产生 APK 或系统镜像。

Fork 中若尚未启用 Actions，先在 Actions 页面启用。推送工作流需要 GitHub CLI 登录具备 `workflow` 权限，普通 `repo` 权限不一定足够。

## 完整镜像任务的前提

在仓库 Settings → Secrets and variables → Actions 中设置两个 repository secrets：

- `H700_ANDROID_URL`：`android.tar.gz` 的可下载 HTTPS 地址，22,273,432,977 字节，SHA256 `94f4b20c4805f3ab1a618e2ebf933d87fcc288632da692d870170e0f6d78ae09`。
- `H700_IMAGE_URL`：`ROC_OS_ARM64_ver0.0.1.img.gz` 的可下载 HTTPS 地址，591,043,813 字节，SHA256 `e72580e8c4e4afc8b08b50570ad6beebf46a435ee6e8b32b7a943f21786a6346`。

这些必须是工作流可直接下载的文件地址；百度网盘分享页面不能直接替代。2026-11-17 的匿名检查能提取、列目录，但刚生成的打包下载地址返回 HTTP403 / `31064: file is not authorized`。没有把该未授权链接写入配置，也没有把用户网盘凭证导入 Actions。

指定 0.0.1 是当前公开源码清单的固定构建输入，即使分享中已有 0.0.2，也不能直接替换。

运行器需要 Linux x86_64、systemd/cgroup v2、可用的CPU0和CPU1。入口设置120GiB空闲空间的保守规划门槛：完整基础包约22.3GB、解压源码约48.4GB，此外还有编译和打包输出；120GiB不是已实测的最大用量或上游硬性要求。GitHub标准运行器只保证14GB可用空间，不能保证通过这个门槛。脚本不会自动删除预装软件以腾空间。

保留项目资源限制：合计1CPU、CPU0–1亲和性、6GiB内存上限、512MiB交换上限、nice19、空闲I/O、`-j1`、每个受限任务最多3小时。镜像 job 最多350分钟，GitHub-hosted job 平台上限6小时；冷编可能超时，不承诺一轮完成。当前每次创建新工作目录，不提供跨运行的编译缓存或自动续编。

## 触发完整构建

Actions → H700 cloud build → Run workflow，选择本分支，将 `build_image` 设为 true。`runner` 默认 `ubuntu-24.04`；如使用已登记且有足够磁盘的独立 Linux 构建机，可填写它的唯一自托管标签。工作流不会注册机器或创建付费运行器。

CLI 示例：

```sh
gh workflow run h700-cloud-build.yml --repo mpmp666/H700Android \
  --ref codex/github-actions-h700 -f build_image=true -f runner=ubuntu-24.04
```

完整任务依次检查前提、安装构建依赖、下载并核对精确输入、解包、提取镜像输入、创建临时签名身份、应用公开覆盖层、编译system/vendor/ramdisk，再执行整卡打包和完整读回验证。仅打包工具返回成功后上传 `ROC_OS_ARM64_community.img.gz`、收据和SHA256。

签名私钥不进入日志、缓存或artifact。当前是一次性试编身份，运行器消失后私钥不可恢复，后续同签名升级需要另行安排持久的私有签名管理。构建日志和公开收据保留7天，镜像artifact保留1天；镜像约0.6GB，须考虑账号artifact存储额度。

## RG35XX Pro 的适用边界

用户提供的RG35XX Pro只读检查显示：4.9.170 aarch64内核、约1GB内存，实际LCD输出640×480。当前参考镜像保留原720显示路径，项目没有RG35XX Pro验收记录。编译成功不会自动解决面板适配，不应据此直接覆盖现有启动卡。

本工作流不连接设备、不刷卡，不上传SSH地址、密码、设备日志或原设备数据。
