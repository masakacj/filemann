# FileMann

FileMann EasySign 单 App 版：本地媒体库、逐帧播放器和 SMB/NAS 归档已经合并为一个主界面。

## 主界面

不再使用独立“归档”Tab。

媒体页面顶部会在有归档任务时显示 NAS 归档卡片，包括：

- 总进度、速度
- 暂停 / 继续
- 重复文件处理
- NAS 双边校验结果
- 单任务状态
- SMB / NAS 设置

媒体多选后直接点：

```
归档到 NAS
```

即可加入并启动归档。

## 缩略图大小

右上角：

```
… → 缩略图大小
```

支持紧凑 / 小 / 中 / 大，选择会自动记忆。

## 视频播放

- 上一帧 / 下一帧：点按精确逐帧
- 按住上一帧 / 下一帧：连续逐帧
- 长按视频画面：临时 2× 播放，松手恢复
- 双指：局部放大

“视频调整”默认收起，点击后展开。

视频调整只作用于**当前这一次播放会话**：

- 不改写源文件
- 不保存 sidecar
- 退出视频后自动还原
- 不影响其他视频

## 快捷指令分享

中转目录：

```
我的 iPhone
└─ FileMann
   └─ Shortcut Inbox
```

FileMann 会把快捷指令复制进来的图片 / 视频移动到私有媒体库。

### 删除相册原件开关

FileMann：

```
… → 快捷指令复制后询问删除相册原件
```

这个开关会同步到：

```
我的 iPhone / FileMann / FileMann Shortcut Settings.txt
```

文件内容为：

```
ask_delete_originals=1
```

或：

```
ask_delete_originals=0
```

快捷指令可以读取这个文件，只有值为 1 时才显示“是否删除相册原件？”确认，然后把最初的“快捷指令输入”交给“删除照片”。

这样开关由 FileMann 控制，但真正的相册删除仍由持有原始 Photos 输入的快捷指令完成，避免 FileMann 根据文件名猜测照片身份。

## FileMann 内相册导入

```
FileMann → 右上角照片+
```

这一条通过 PhotoKit asset identifier 精确删除，因此仍可使用：

```
FileMann 导入后清理相册原件
```

## 签名与 Bundle ID

FileMann 固定使用独立 Bundle ID：

```
com.masakacj.filemann
```

不要再改成 `tg.unitgqq2709.tool1`，因为该 Bundle ID 已被其他 App 使用；iOS 会把相同 Bundle ID 视为同一个 App，从而发生覆盖安装。

你当前上传的 mobileprovision 是精确绑定到：

```
tg.unitgqq2709.tool1
```

因此这份描述文件不能用于安装当前这个独立 Bundle ID 的 FileMann。需要另一份匹配 `com.masakacj.filemann` 的描述文件，或者允许自定义 Bundle ID 的 wildcard profile。

IPA 不包含 Share Extension，也不依赖 App Group。

## Release

最新 unsigned arm64 IPA 固定发布到 `latest` Release。
