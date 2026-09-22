# FileMann

iOS 本地媒体库 + SMB/NAS 归档工具。

## 两种相册入口

### 1. 最快：iOS 相册 → 分享 → 保存到 FileMann

Share Extension 会把图片/视频复制到 FileMann 媒体库。这个入口最省操作，但 iOS 的普通分享数据不可靠地携带可删除的 `PHAsset` 身份，所以 FileMann **不会猜测并删除相册原件**。

### 2. 可安全清理原件：FileMann → 从相册导入

FileMann 使用带 `PHPhotoLibrary.shared()` 的系统 Photos Picker，因此能保留每个选择项的 PhotoKit asset identifier。

默认开启：

`导入后清理相册原件`

流程：

1. 复制到 FileMann。
2. 对复制文件做 byte-size 校验。
3. 保存 PhotoKit asset identifier。
4. 导入全部完成后请求 PhotoKit 删除对应原件。
5. iOS 显示系统删除确认。
6. 用户确认后，相册原件进入 Photos 的“最近删除”。

如果用户取消系统删除确认，FileMann 本地副本仍保留。

## FileMann 媒体库

- 图片、视频网格浏览
- 图片/视频预览
- 视频播放、时间轴
- 上一帧 / 下一帧逐帧查看
- 图片、视频双指局部放大
- 非破坏性调整：曝光、鲜明度、高光、阴影、对比度、亮度、黑点、饱和度、自然饱和度、色温、色调、锐度、清晰度、晕影
- 调整参数保存在 sidecar，原始媒体不改写

## SMB / NAS 归档

- SMB2 / SMB3（AMSMB2）
- `.filemann-partial` 断点续传
- 总进度 / 单文件进度 / 实时速度
- byte-for-byte 重复文件检测
- 整批文件数 + 总字节数校验通过后才允许删除 FileMann 本地源文件

## 自签名

IPA 包含主 App 和 Share Extension：

`FileMann.app/PlugIns/FileMannShare.appex`

主 App 与扩展通过 App Group 共享媒体：

`group.com.masakacj.filemann`

自签时需要递归签名主 App、AMSMB2.framework、FileMannShare.appex，并且主 App 与扩展的 provisioning profile 都要允许对应 App Group。

## Release

GitHub Actions 构建 unsigned arm64 IPA：

`FileMann-unsigned.ipa`

固定 Release tag：

`latest`
