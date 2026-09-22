# FileMann

FileMann EasySign 版：iOS 本地媒体库 + SMB/NAS 归档工具。

## EasySign 签名目标

这版专门适配当前 mobileprovision：

```
Bundle ID: tg.unitgqq2709.tool1
```

IPA 只包含一个主 App，不再包含 Share Extension，也不请求 App Group entitlement。

轻松签中：

1. 导入 `FileMann-unsigned.ipa`
2. 选择你的 p12
3. 选择对应的 mobileprovision
4. 不额外修改 Bundle ID
5. 签名并安装

## 相册导入

入口：

```
FileMann → 媒体 → 从相册导入
```

支持多选图片和视频。

默认可以开启：

```
导入后清理相册原件
```

流程：

1. 系统 Photos Picker 选择图片/视频。
2. 复制到 FileMann 私有 Sandbox。
3. 对复制文件做 byte-size 校验。
4. 保存 PhotoKit asset identifier。
5. 全部导入完成后请求 PhotoKit 删除对应相册原件。
6. iOS 显示系统删除确认。
7. 用户确认后，相册原件进入“最近删除”。

如果取消系统删除确认，FileMann 已导入副本仍保留。

## 媒体功能

- 图片、视频网格浏览
- 视频播放和时间轴
- 上一帧 / 下一帧逐帧查看
- 图片、视频双指局部放大
- 非破坏性调整：曝光、鲜明度、高光、阴影、对比度、亮度、黑点、饱和度、自然饱和度、色温、色调、锐度、清晰度、晕影
- 调整参数保存为 sidecar，原始媒体不改写

## NAS 归档

- SMB2 / SMB3（AMSMB2）
- `.filemann-partial` 断点续传
- 总进度 / 单文件进度 / 实时速度
- byte-for-byte 重复文件检测
- 整批文件数 + 总字节数校验通过后，才允许删除 FileMann 本地源文件

## Release

GitHub Actions 云端生成 unsigned arm64 IPA：

```
FileMann-unsigned.ipa
```

固定 Release tag：

```
latest
```
