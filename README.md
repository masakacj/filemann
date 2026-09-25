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


## WebDAV 本地 / 远程双地址

WebDAV 现在支持两个地址：

```
本地地址  http://192.168.x.x:5000/Share
远程地址  https://nas.example.com/Share
```

连接策略固定为：

```
先探测本地地址
→ 本地可达：使用本地
→ 本地不可达：自动使用远程
```

归档、目录浏览和 NAS 媒体浏览都使用同一套策略。

远程地址建议使用可信 HTTPS。外网使用 HTTP 会暴露 WebDAV Basic Auth 和媒体内容，不建议。

## NAS 媒体浏览

主界面右上角的“云盘”按钮可以直接浏览当前 WebDAV 归档目录中的图片和视频。

- 目录使用 WebDAV PROPFIND 懒加载。
- 图片缩略图只在进入屏幕后按需下载，并写入本地缩略图缓存。
- 图片全屏查看支持双指放大。
- 视频使用 AVAssetResourceLoader + HTTP Range 分段读取，不会先完整下载视频再播放。
- 远程视频保留 FileMann 的手势播放器：
  - 左侧点击：上一帧
  - 右侧点击：下一帧
  - 中间点击：播放 / 暂停
  - 左侧长按：1.5× 倒退
  - 右侧长按：1.5× 快进
  - 下方区域长按并左右拖动：逐帧拖动
  - 双指：局部放大
- 视频 Range 请求会优先使用当前可用的本地地址，并保留远程地址作为备用。


## 独立 NAS Tab

主界面现在分成两个底部 Tab：

```
本地
NAS
```

“本地”负责手机媒体、快捷指令导入和归档任务；“NAS”专门负责 WebDAV 远程目录、图片和视频浏览。NAS Tab 仍然使用本地优先、远程失败回退策略。


## 缓存管理

设置页新增缓存管理：

- 显示当前缓存占用。
- 可一键“清理缓存”。
- 最大缓存支持 256 MB / 512 MB / 1 GB / 2 GB / 4 GB，默认 512 MB。
- NAS 原图、NAS 缩略图统一计入总上限，超过上限后按最久未使用顺序自动淘汰。
- 启动时会清理旧版本遗留的 URLSession 网络磁盘缓存。
- 清理缓存不会删除本地媒体库、Shortcut Inbox、归档任务或 NAS 文件。


## 存储占用

设置页会分别显示：

- FileMann 私有本地媒体（Application Support / FileMann / Media / Originals）
- Shortcut Inbox
- NAS 图片/缩略图缓存
- 元数据与临时文件
- 可管理合计

“清理 NAS 缓存”只清可重建缓存；如果 iPhone“存储空间”仍显示数 GB，通常是历史导入到 FileMann 私有媒体库的原图/视频。

可通过“删除 FileMann 本地媒体”单独清理这些文件。存在未完成归档任务时，该操作会被禁用，避免误删仍待上传的源文件。外部映射文件夹和 NAS 文件不会被删除。
