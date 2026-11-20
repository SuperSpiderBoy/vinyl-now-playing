# Vinyl Now Playing — Apple Editorial Live Wallpaper

<p align="center">
  <img src="./assets/preview.png" alt="Vinyl Now Playing Desktop Preview" width="90%">
</p>

一款基于 **Lively Wallpaper** 与 **Windows SMTC（系统媒体控制）** 的免费开源低功耗桌面动态音乐壁纸。  
无需任何 Spotify / Last.fm / Apple Developer API Key，原生兼容 **MyGo Music**、网易云音乐、Apple Music、Spotify、浏览器音频等所有接入 Windows 媒体控制的播放器，在桌面上呈现 **黑胶唱片舞台 + Apple Music 级官方动态封面与逐字浮动歌词 + 动态取色流光背景**。

---

## 核心特性

- **两阶段 Apple Music 官方动态封面（高覆盖率 + 秒开体验）**：
  - **第一阶段（瞬时静态展示）**：切歌瞬间优先渲染本地 SMTC 居中裁切封面（`<20ms`）并提取五色极光调色板，同步通过 `/artwork` 快速升级至 `800×800` 高清静态封面，全程零白屏、零等待。
  - **第二阶段（后台直连加载并平滑替换）**：后台并发通过 `/motion` 直连 Apple Music `amp-api`（自动提取并缓存公共 Storefront JWT），按语种自动路由 `US` / `CN` / `HK` / `JP` / `KR` 多地区商店与多版本（Standard / Explicit / Deluxe）检索 `editorialVideo`；内置 Win32 繁简统一归一化与跨语种艺人名兼容，支持 `Various Artists` 电影原声带、`Remix` 单曲及无专辑标签按曲目反查所属专辑，同时兼容 `1:1` 方形与 `3:4` 竖版动态封面，解析 `768×768` H.264 `.mp4` 直链并在首帧就绪后平滑淡入替换。
  - **持久化磁盘缓存与失效自愈**：已解析的动态封面按专辑持久化缓存于 `%LOCALAPPDATA%\VinylNowPlaying\motion_cache.json`（上限 200 张专辑，约 40 KB），同专辑或再次播放 `<20ms` 秒出；若 CDN 链接失效自动静默刷新一次。
- **毫秒级逐字浮动歌词**：
  - 优先拉取网易云 **YRC 逐字时间戳 + 双语翻译**，无 YRC 时自动回退至 `lrclib.net` 并按中英文词长合成流畅逐字节奏。
  - 逐字从左向右高亮扫光、微幅上浮泛光、景深渐进虚化（远屏行跳过 GPU 模糊层），以及纯音乐前奏呼吸三点提示。
  - 英文默认采用本地打包的 **Playfair Display**（仅 ~82 KB）杂志衬线体，中文默认采用清晰锐利的系统无衬线体（可选杂志中宋与楷体衬线）。
- **低能耗流光背景 & 黑胶细节**：
  - **96×54 超低功耗流体极光网格（12fps 硬件双线性放大）**，彻底消除全屏大半径高斯模糊的 GPU 负担；叠加 `0.375×` 降分辨率微尘光斑（20fps）、35mm 胶片颗粒与纯 CSS 有机呼吸光晕（零 WASAPI FFT CPU 占用）。
  - 博朗（Braun）风格阳极氧化铝唱臂：播放时落针在唱片沟槽并滑出旋转黑胶，暂停时抬臂归位并收起黑胶。
- **桌面直接交互**：
  - **拖动 / 点击进度条**：鼠标悬停自动加粗并显示时间预览气泡，松手即跳转，歌词 0ms 即时跟进。
  - **点词跳转**：点击右侧任意一句歌词直接跳到该句演唱时间点。
  - **悬停播控胶囊**：鼠标停在封面底部浮现半透明 上一首 / 播放暂停 / 下一首 控制条，移开自动隐身。
- **极速并发桥接 & 全屏 0% 休眠**：
  - 本地路由（`/state`、`/cover`、`/seek`、`/control`）主线程直出（`<2ms`，零 Runspace 分配与内存泄漏）；外网路由（`/artwork`、`/motion`、`/lyrics`）运行于轻量 3 线程异步池，三路并发互不阻塞。
  - 接入 Lively `--pause-event true`，窗口遮挡或全屏应用时自动冻结动画、暂停动态封面视频与桥接轮询（CPU/GPU 降至 0%）；全套壁纸仅占 **0.16 MB** 磁盘空间。

---

## 快速安装（新电脑一键部署）

### 环境准备
1. Windows 10 / 11
2. 安装并打开过一次 [**Lively Wallpaper**](https://github.com/lively-community/lively/releases)（免费开源）：
   ```powershell
   winget install rocksdanister.LivelyWallpaper
   ```

### 一键部署
```powershell
git clone https://github.com/SuperSpiderBoy/vinyl-now-playing.git
cd vinyl-now-playing
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

脚本会自动完成：
1. 将壁纸与本地字体包部署到 `%LOCALAPPDATA%\Lively Wallpaper\Library\wallpapers\vinyl.nowplaying`
2. 将同步桥接脚本部署到 `%LOCALAPPDATA%\VinylNowPlaying\scripts\`
3. 注册并启动开机自启计划任务 `VinylSyncBridge`（静默隐藏运行）

最后打开 **Lively Wallpaper**，点击 **「Vinyl Now Playing (专辑黑胶)」** 即可应用；建议在 Lively 设置中开启「随 Windows 启动」并将「壁纸交互」设为鼠标（`InputForward: Mouse`）以支持桌面拖动进度条。

---

## 个性化定制

在 Lively Wallpaper 中右键该壁纸 → **「自定义壁纸」**，可实时调整以下选项：

| 选项 | 说明 |
|---|---|
| **歌词字体** | 衬线英文 × 原版中文（默认） / 杂志中宋 / 楷体衬线 |
| **Apple Music 动态封面** | 开关官方 `.mp4` 动态专辑封面（实时生效） |
| **黑胶唱臂动画 / 黑胶旋转** | 开关金属唱臂落针与黑胶转动 |
| **双语歌词翻译** | 开关网易云双语译文行 |
| **背景微尘光斑 / 胶片颗粒** | 开关氛围漂浮粒子与 35mm 噪点质感 |
| **右上角极简时钟** | 开关右上角日期与时间显示 |
| **歌词字号缩放** | `85%` – `125%` 自由缩放 |

---

## 项目结构

```text
vinyl-now-playing/
├── assets/
│   └── preview.png               # 桌面实拍效果预览
├── scripts/
│   ├── sync_bridge.ps1           # Windows SMTC + 两阶段动态封面（amp-api & 磁盘缓存）+ 歌词桥接服务
│   └── start_bridge.vbs          # 无窗口静默启动器
├── wallpaper/
│   ├── fonts/                    # 本地打包的 Playfair Display 字体 (~82 KB)
│   ├── index.html                # 壁纸前端主舞台（低功耗流体网格 + 黑胶 + 两阶段封面 + 逐字歌词）
│   ├── LivelyInfo.json           # Lively 壁纸清单（启用 --system-nowplaying --pause-event true）
│   ├── LivelyProperties.json     # Lively 自定义面板配置
│   └── thumbnail.png             # 壁纸缩略图
├── install.ps1                   # 新设备一键部署脚本
├── uninstall.ps1                 # 一键卸载清理脚本
└── LICENSE                       # MIT License
```

---

## 卸载与常见问题

- **一键卸载清理**：
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
  ```
- **检查桥接服务与动态封面缓存状态**：浏览器访问 `http://127.0.0.1:28973/state` 或 `http://127.0.0.1:28973/debug`（可查看 `hasAppleToken`、`motionDiskCache` 等实时指标）。
- **Lively 无法挂载到桌面背景**：请勿以“管理员身份”启动 Lively，否则无法挂载至普通权限的桌面 `WorkerW` 图层。
- **播放器内拖动进度条延迟**：部分第三方播放器（如 MyGo Music）自身每 2~3 秒才向 Windows SMTC 推送一次进度更新；建议直接拖动桌面壁纸上的进度条或点击歌词行，可实现 0ms 即时同步。
- **哪些专辑支持动态封面**：所有在 Apple Music 官方曲库中提供 `editorialVideo`（动态专辑封面）的欧美与华语专辑均会自动匹配并缓存（例如 The Weeknd《After Hours》《Dawn FM》、SZA《SOS》、Travis Scott《UTOPIA》、Taylor Swift《Midnights》、周杰伦《最伟大的作品》、邓紫棋《启示录》等）；Apple Music 官方本身为静态封面的专辑则保持高清静态封面展示。

---

## Credits

- Wallpaper host: [Lively Wallpaper](https://github.com/lively-community/lively)
- Fonts bundled locally: [Playfair Display](https://fonts.google.com/specimen/Playfair+Display)
- Lyrics providers: NetEase Cloud Music & [LRCLIB](https://lrclib.net/)
- Motion artwork: Apple Music official catalog (`editorialVideo`)
