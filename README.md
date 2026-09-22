# FileMann

iOS 本地媒体库 + SMB/NAS 归档工具。

## 当前工作流

1. 在 iOS 相册选择图片/视频。
2. 分享 → **保存到 FileMann**。
3. Share Extension 把原始媒体复制到 FileMann 的共享媒体目录。
4. FileMann 中可浏览图片和视频；图片/视频调整以 sidecar 方式无损保存。
5. 视频支持暂停后上一帧/下一帧、时间轴拖动、双指局部放大。
6. 需要归档时，从媒体库多选 → 加入归档 → SMB 断点续传 → 整批校验 → 可选删除本地副本。

## 媒体调整

当前有：

- 曝光
- 鲜明度
- 高光
- 阴影
- 对比度
- 亮度
- 黑点
- 饱和度
- 自然饱和度
- 色温
- 色调
- 锐度
- 清晰度
- 晕影

调整是**非破坏性的**：原始媒体不改写，参数保存在 FileMann sidecar 中。

## SMB 归档

- SMB2 / SMB3（AMSMB2）
- `.filemann-partial` 临时文件
- 按 NAS 上 partial 的真实字节数断点续传
- 总进度 / 单文件进度 / 实时速度
- byte-for-byte 重复文件检测
- 整批文件数 + 总字节数校验通过后才允许删除手机源文件

## 自签名的重要说明

FileMann 现在包含一个 Share Extension，主 App 与 Extension 通过 App Group 共享媒体目录：

```
group.com.masakacj.filemann
```

所以自签时需要：

- 对主 App 和 `PlugIns/FileMannShare.appex` 都递归签名；
- provisioning profile / signer 必须保留并允许 `com.apple.security.application-groups`；
- App Group 值必须包含 `group.com.masakacj.filemann`。

如果签名后 App Group 被移除，主 App 可以启动，但“保存到 FileMann”无法把媒体交给主 App。

## 云端构建

GitHub Actions 使用标准 `macos-15` runner 构建 unsigned arm64 IPA。

最新构建始终发布为：

```
FileMann-unsigned.ipa
```

Release tag：

```
latest
```
