# KAlertXC — 今日水印相机 Tweak（GitHub Actions 可编译）

与参考改版 `TG-ioskuka.dylib` 同机制：**运行时 hook，不修改主程序逻辑**。
无需 Theos、无需 substrate —— 用纯 clang 编译，CI 上直接产出 dylib。

## 三个功能与 hook 点（均已对照 3.0.496 二进制确认）

| 功能 | Hook 目标 | 二进制证据 |
|---|---|---|
| 改定位 | `XHLocationManager -latestLocation`<br>`CLLocationManager -locationManager:didUpdateLocations:`<br>`AMapLocationManager -amapLocationManager:didUpdateLocation:reGeocode:` | selector `latestLocation` @ `0x107948f0d` |
| 改时间 | `NSDateFormatter -stringFromDate:` / `-dateFromString:` | `0x1085439a2` / `0x108525608` |
| 换照片 | `UIImageView -setImage:`<br>`XHCameraKit -capturedImage:mattePixelBuffer:time:imageOrientation:error:` | `setImage:` @ `0x107c4d7cb`；方法实现 @ `0x10744e2cc` |

## Hook 机制

优先用 `MSHookMessageEx`（若运行时已加载 substrate/libhooker/ellekit），
否则回退到 ObjC runtime 的 `method_setImplementation`。

**这是关键设计**：dylib 不链接 `libsubstrate`，所以：

- 用 `clang -dynamiclib` 就能编译，不需要 Theos；
- 注入后**不要求**目标已带 substrate；
- 如果目标里已经有 substrate（参考改版就带了 `libsubstrate.dylib`），自动走 substrate 路径。

## 用 GitHub Actions 编译

仓库已含 `.github/workflows/build.yml`，`macos-14` runner 自带 Xcode：

1. 把 `tweak/` 和 `.github/workflows/build.yml` 推到仓库。
2. 提供底包（三选一）：
   - 在仓库 **Settings → Variables** 建 `TWEAK_BASE_IPA_URL` 指向 IPA 下载地址；
   - 或把 IPA 放成 `tweak/base.ipa`（需 Git LFS）；
   - 或不提供，只产出 dylib。
3. Actions → `build-tweak` → Run workflow。
4. 产物在 `KAlertXC-build` artifact：
   - `KAlertXC.dylib`（arm64+arm64e fat）
   - `XCamera-KAlertXC-unsigned.ipa`（若提供了底包，已注入并 `ldid` 签过）

最后用 Sideloadly / AltStore 以**你自己的证书**签名安装。

## 本地（macOS）编译

```bash
brew install ldid
OUT_DIR=./out ./tweak/compile.sh
python3 tweak/inject.py <底包.ipa> out/KAlertXC.dylib out/XCamera-KAlertXC.ipa
```

## 注入器行为（已用真实二进制验证）

`inject.py` 纯 Python 添加 `LC_LOAD_DYLIB`，自动选模式：

- **pad 模式**：`XCamera` 的加载命令区到 `__text` 之间有 **16,048 字节 padding**，
  写进去即可，**文件大小不变、所有段偏移不动**（实测 delta = 0 字节）。
- **grow 模式**：padding 不足时，按整页（0x4000）插入并同步修正所有段/节/链接编辑偏移，
  保持页对齐。
- 幂等：重复注入会识别 `already` 并跳过。

实测结果：161 条加载命令全部合法，6 个段文件偏移全部页对齐。

## 重要限制

1. **未真机验证**。hook 点的选择器与实现地址来自对 3.0.496 二进制的静态确认。
2. Swift 类（`XHLocationManager`）未暴露 ObjC 方法时，`NSClassFromString` 能拿到类，
   但方法可能不在 ObjC 方法表里 —— 如果日志出现 `%@ -%@ missing`，
   说明该 hook 未生效，需要改用从 Swift 符号地址直接 hook（此时日志会明确告诉你哪个没挂上）。
3. 换照片用**原地绘制到原 CVPixelBuffer**，不改指针。参考改版日志里
   `v22 in-place draw ok=%d (params pointers unchanged)` 说的就是这个约束：
   替换 buffer 指针会让下游访问已释放内存而崩溃。
4. 只处理定位/时间/照片三项，不涉及会员与次数限制（那两项是服务端数据）。
