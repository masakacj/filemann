# FileMann

FileMann EasySign 版：iOS 本地媒体库 + SMB/NAS 归档工具。

## EasySign 签名目标

当前 Bundle ID：

```
tg.unitgqq2709.tool1
```

IPA 只包含主 App，不包含 Share Extension，也不依赖 App Group。

## 快捷指令分享方案

FileMann 会创建并公开：

```
我的 iPhone
└─ FileMann
   └─ Shortcut Inbox
```

这是快捷指令与 FileMann 之间的中转目录。

推荐创建一个名为：

```
保存到 FileMann
```

的快捷指令，并开启“在共享表单中显示”。

快捷指令步骤：

1. 接收共享表单中的“图像”和“媒体”。
2. “存储文件”：输入使用“快捷指令输入”，目标固定到“我的 iPhone / FileMann / Shortcut Inbox”，关闭“询问存储位置”。
3. “打开 URL”：`filemann://inbox`。也可以改成“打开 App → FileMann”。
4. 第一轮测试先不要加“删除照片”。

操作：

```
相册多选
→ 分享
→ 保存到 FileMann
→ 文件写入 Shortcut Inbox
→ 自动打开 FileMann
→ FileMann 自动接管 Shortcut Inbox
→ 移入私有媒体库
→ Shortcut Inbox 清空
```

FileMann 每次启动、回到前台，都会自动扫描 Shortcut Inbox。

Shortcut Inbox 中图片/视频会被移动到 FileMann 的私有 Application Support 媒体库。移动后会再次检查文件字节大小，只有大小一致才记为成功导入。非图片/视频文件不会被删除，会留在 Inbox。

第一轮验证成功后，可以在快捷指令的“存储文件”动作之后加入“删除照片”，让 iOS 对共享输入执行照片删除。建议先用 1 张图片和 1 个短视频测试完整流程，再开启删除。

## FileMann 内直接相册导入

入口：

```
FileMann → 媒体 → 从相册导入
```

这个入口能保留 PhotoKit asset identifier，因此可以在导入校验完成后安全请求清理相册原件。

## 媒体功能

- 图片、视频网格浏览
- 视频播放和时间轴
- 上一帧 / 下一帧逐帧查看
- 图片、视频双指局部放大
- 曝光、高光、阴影、对比度、亮度、黑点、饱和度、自然饱和度、色温、色调、锐度、清晰度、晕影
- 编辑参数使用 sidecar 非破坏保存

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


### 为什么不是 Documents/Inbox

iOS 的 `Documents/Inbox` 是系统保留的导入目录，应用不能自行创建，所以快捷指令中转目录使用：

```
我的 iPhone / FileMann / Shortcut Inbox
```
