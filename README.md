# FileMann

iOS 上的 SMB/NAS 归档工具，目标是解决“大量文件从 Documents 等 File Provider 归档到 SMB 后删除手机本地文件”时缺少可靠进度和断点续传的问题。

## 当前 MVP

- 通过 iOS 系统文件选择器从 Documents 等 File Provider 多选文件
- 保存 security-scoped bookmark，App 重启后保留任务
- SMB2/SMB3 上传（AMSMB2 4.0.3）
- 使用 `.filemann-partial` 临时文件
- 根据 NAS 上 partial 的真实大小进行字节级断点续传
- 总进度、单文件进度、实时速度
- 上传完成后校验远端文件大小
- 原子重命名 partial 为最终文件
- 可选：归档成功后删除源文件
- 密码保存在 iOS Keychain
- 传输期间保持屏幕常亮；切后台后会尽量使用 iOS background task 延长运行时间

## SMB 路径

如果 NAS 路径是：

```
\\NAS\storage\Documentsf\Apps
```

则设置为：

- 服务器：`NAS` 或 NAS IP
- 共享名：`storage`
- 归档目录：`Documentsf/Apps`

## 云端构建

工程由 XcodeGen 生成，GitHub Actions 使用标准 `macos-15` runner 编译。

签名流程沿用 laocai-manager 的 zsign 方案。要生成可直接自签安装的 Release IPA，在本仓库 Settings → Secrets and variables → Actions 中配置：

- `IOS_P12_BASE64`
- `IOS_P12_PASSWORD`
- `IOS_MOBILEPROVISION_BASE64`

没有配置签名 secrets 时，Actions 仍会执行完整的 unsigned device build，用于云端编译检查，但不会发布 signed Release。

> 不要把 p12、密码或 mobileprovision 提交到仓库。仓库可以公开，签名材料必须只放 GitHub Secrets。

## Release

成功签名后，workflow 会维护一个 `latest` Release，并上传：

```
FileMann.ipa
```

## 说明

AMSMB2 本身为开源项目，并动态链接其 SMB 依赖。当前项目主要面向自签/个人设备使用。
