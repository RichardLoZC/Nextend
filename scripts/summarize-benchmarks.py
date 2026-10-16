#!/usr/bin/env python3
"""Summarize saved device measurements without running or interrupting a session."""
import argparse
import csv
import json
import statistics
from pathlib import Path


def mean(rows, key):
    values = [row[key] for row in rows if isinstance(row.get(key), (int, float))]
    return statistics.mean(values) if values else 0.0


def describe(path, minimum_seconds):
    report = json.loads(path.read_text())
    samples = report.get('samples', [])
    stable = samples[3:]
    duration = samples[-1]['seconds'] if samples else 0
    return {
        'file': path.name,
        'success': report['success'],
        'completed': report['success'] and duration >= minimum_seconds - 1,
        'resolution': f"{report['width']}×{report['height']}",
        'targetFps': report['targetFps'],
        'codec': report['codec'].upper(),
        'transport': 'USB' if report['transport'].startswith('usb') else 'Wi-Fi',
        'seconds': duration,
        'encodeFps': mean(stable, 'encodeFps'),
        'renderFps': mean(stable, 'renderFps'),
        'ackP50Ms': report['captureToDecodeAckP50Ms'],
        'ackP95Ms': report['captureToDecodeAckP95Ms'],
        'averageMbps': samples[-1].get('megabitsPerSecond', 0) if samples else 0,
        'thermalMax': max((s.get('thermal', 0) for s in samples), default=0),
    }


def stability_section(directory):
    path = directory / 'usb-native-60-30min.json'
    resources_path = directory / 'usb-native-60-30min-resources.json'
    if not path.exists() or not resources_path.exists():
        return '按用户要求改为 30 分钟。当前测试尚未完成，不计为通过。\n'
    report = json.loads(path.read_text())
    resources = json.loads(resources_path.read_text())
    samples = report.get('samples', [])
    duration = samples[-1]['seconds'] if samples else 0
    validation = json.loads((directory / 'stability-validation.json').read_text())
    passed = validation['completedRequestedDuration'] and duration >= 1800
    if not passed:
        return f"30 分钟测试未通过：记录持续 {duration:.1f} 秒，结束原因为“{report['reason']}”。\n"
    early = [s for s in samples if 60 < s['seconds'] <= 360]
    late = [s for s in samples if duration - 300 < s['seconds'] <= duration]
    memory = [s['macRssMB'] for s in resources['samples'] if s.get('elapsedSeconds', 0) >= 60 and 'macRssMB' in s]
    pad = [s['padPssMB'] for s in resources['samples'] if 'padPssMB' in s]
    steady = [s for s in samples if s['seconds'] > 60]
    text = f'''已完成 **{duration:.1f} 秒**连续桌面采集，按用户指定的半小时结束并完成清理。原生 3200×2136、60 fps、HEVC、USB ADB，主动停止前未发生意外中断。

| 指标 | 启动后第 1–6 分钟 | 最后 5 分钟 |
|---|---:|---:|
| 平均编码 fps | {mean(early, 'encodeFps'):.2f} | {mean(late, 'encodeFps'):.2f} |
| 平均 Pad 呈现回调 fps | {mean(early, 'renderFps'):.2f} | {mean(late, 'renderFps'):.2f} |
| 滚动解码确认往返 P95 的均值，ms | {mean(early, 'captureToDecodeAckP95Ms'):.2f} | {mean(late, 'captureToDecodeAckP95Ms'):.2f} |

排除首分钟后，平均编码 {mean(steady, 'encodeFps'):.2f} fps，Pad 呈现回调 {mean(steady, 'renderFps'):.2f} fps。末次滚动往返 P50 / P95 为 {report['captureToDecodeAckP50Ms']:.2f} / {report['captureToDecodeAckP95Ms']:.2f} ms。最大未确认队列为 {max(s['pending'] for s in samples)} 帧；Android 系统热状态最大值为 {max(s.get('thermal', 0) for s in samples)}（0 表示系统未报告热压力，不是温度读数）。
'''
    if memory:
        text += f'\nMac 进程 RSS 在首分钟后为 {min(memory):.1f}–{max(memory):.1f} MB，每 30 秒采样。'
    if pad:
        text += f'Pad 应用 PSS 为 {min(pad):.1f}–{max(pad):.1f} MB，每 5 分钟采样。'
    text += '\n\n原命令按 3600 秒启动，用户在运行期间将验收时长改为半小时，因此到时发送 SIGTERM 主动停止。原始 JSON 保留 `success=false` 和信号中止原因，未改写成自然完成；`stability-validation.json` 单独确认已达到 1800 秒及清理结果。用户反馈触摸 Pad 时温度没有明显变化。\n\n测试期间用 `caffeinate -di -w PID` 防止空闲睡眠，随测试进程结束释放；未修改持久睡眠设置。这轮验收不包含实际睡眠、物理拔线或 VPN 策略切换。\n'
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parent.parent
    parser.add_argument('--reports', type=Path, default=root / 'outputs/benchmarks')
    args = parser.parse_args()
    cases = [
        'desktop-native-60-verified', 'desktop-native-90-verified',
        'desktop-native-120-verified', 'desktop-reduced-120-verified',
        'desktop-h264-60-verified', 'wifi-low-latency-60',
    ]
    results = [describe(args.reports / f'{case}.json', 60 if case.startswith('wifi') else 30) for case in cases]
    header = '| 传输 | 分辨率 | 目标 fps | 编码 | 秒 | 编码 fps | Pad 呈现回调 fps | 往返 P95 ms | 完成 |\n|---|---|---:|---|---:|---:|---:|---:|---|\n'
    table = header + '\n'.join(
        f"| {r['transport']} | {r['resolution']} | {r['targetFps']} | {r['codec']} | {r['seconds']:.0f} | {r['encodeFps']:.2f} | {r['renderFps']:.2f} | {r['ackP95Ms']:.2f} | {'是' if r['completed'] else '否'} |"
        for r in results
    )
    incomplete = [r['file'] for r in results if not r['completed']]
    completion = ('以下记录未正常完成预定时长：' + '、'.join(incomplete) + '，不计为通过。') if incomplete else '以上短测均正常完成预定时长。'
    thermal = max(r['thermalMax'] for r in results)
    content = f'''# PadBridge 实测验证报告

测试日期：2026-10-16。设备为 M4 MacBook Air（24 GB、macOS 27.0.1）与 Xiaomi Pad 7 Ultra（Android 16 / HyperOS 3）。

建议使用 **USB、原生 3200×2136、60 fps、HEVC**。90/120 fps 是可选择的实验目标；这台设备组合的当前实现尚未持续达到原生 90/120 fps。加密无线已在切换局域网后连接通过，短测约 51 fps。

## 测试方法与统计

以下全部使用 `--capture-test`：在真正的虚拟拓展屏显示色条、灰阶、文字和移动标记，经过 ScreenCaptureKit、硬件编码、加密传输、硬件解码，再输出到 Pad Surface。不是绕开屏幕采集的 NV12 合成测试。

原生画面对应 1600×1068 逻辑桌面、2 倍 HiDPI。码率配置为 45 Mbps 的平均码率目标；此测试图压缩后的实际数据量远低于该值，不代表全屏视频或高细节运动画面的负载。Mac 在测试期间也有普通桌面与开发活动。

表中帧率取每秒记录，排除前 3 条后求平均。`Pad 呈现回调 fps` 来自 Android `OnFrameRenderedListener`，可能延迟或批量上报，不能等同于物理屏幕扫描帧率。往返延迟从 Mac 取得采集缓冲开始，到 Pad 释放解码输出并回传确认结束，包含返回传输，不是实测屏幕发光延迟。P50/P95 使用最近最多 6000 帧的滚动样本。

{table}

{completion} Android 热状态最大值为 {thermal}（0 表示系统未报告热压力）。90/120 档的虚拟屏模式和采集频率已到目标，但传输到 Pad 的实际更新约 63 fps；2400×1600、120 fps 目标时约 76 fps。Pad 面板在 90 fps 请求下实际选择 120 Hz。后续优化需继续看编解码耗时和有限队列对吞吐的影响。

补做了 6 帧在途额度对比：原生 120 / 90 fps 目标的回调速度约 63.59 / 63.33 fps，往返 P95 增至 101.40 / 100.38 ms；2400×1600、120 fps 目标时约 84.67 fps、P95 72.25 ms，但 30 秒内记录 25 帧解码丢弃。因此未采用该候选版本，交付仍使用 4 帧额度。候选数据以 `candidate-` 前缀单独保留。

无线使用原生 IPv4 socket 直连并绑定 Mac 的 `en0`。当时系统 HTTP/HTTPS/SOCKS 代理保持启用。更换网络前后均连接成功，但未对 VPN 的所有隧道或防火墙模式做验证。启用 Pad 前台 Wi-Fi 低延迟模式前后，单次短测约 50.2 / 50.7 fps、往返 P95 约 136.0 / 133.7 ms；不足以证明性能改善。

## 半小时 USB 稳定性

{stability_section(args.reports)}

![半小时的帧率、解码确认往返延迟和内存曲线](稳定性曲线.png)
此前一轮 USB 测试在约 513 秒处因连接关闭结束，未计入本轮持续时长。用户更换网络后重新计时，随后将本轮要求调整为半小时。

## 功能与异常路径

| 项目 | 结果 |
|---|---|
| 真正拓展屏与 HiDPI | 60 / 90 / 120 Hz 模式均创建成功，3200×2136 像素、1600×1068 逻辑尺寸，非镜像 |
| H.264 / HEVC | Mac 强制硬编；Pad 查询当前分辨率/帧率的硬解能力，两种编码均完成真机采集 |
| 配对和加密 | USB 获取随机共享密钥；双向身份认证、分方向 AES-GCM 会话密钥；密钥不包含在交付包 |
| 协议检查 | Mac 跨平台加密自测、Android 4 项单元测试通过；真机拒绝超长握手、错误证明、重放、密文篡改、输入注入、慢速滴灌握手，共 6 项 |
| 接收端退出 | 强制停止测试接收器后约 0.39 秒检测并清理；随后重新连接通过 |
| 启动中与连接后退出 | SIGTERM 清理分别约 0.20 / 0.31 秒；立即点断开、立即退出界面也完成清理 |
| 中断显示模式探测 | SIGTERM 返回 143，不再把中断当作成功 |
| 断开后的旧帧 | 已改为不透明等待遮罩，真机观察无旧画面残留 |
| 无线低延迟锁 | 只在无线视频期间持有，断开后已确认释放 |
| 慢启动保活 | 隔离构建注入 10 秒准备延迟：旧版断开且没有编码输出，新心跳版本保持连接并完成 5 秒视频测试 |

## SDR 画面检查

链路使用 BT.709、SDR、8-bit、有限范围、4:2:0。检查了 Pad 的 3200×2136 截图；按其内嵌 Display P3 / sRGB transfer ICC 配置转换到 sRGB 后再取样。色条黑白端点为 0 / 255，灰阶没有大于 2 级的反向跳变，中文和代码测试字可辨识。原始预览 PNG 未改色。

这验证了测试画面的数字解码结果，未证明物理屏幕色准或肤色准确度；未使用校色仪。4:2:0 仍会损失彩色细线细节。10-bit、广色域和 HDR 尚未实现。

## 已实现边界与未完成项

- 已交付 Mac / Android 配套客户端、USB 优先连接、加密无线、手动重连、性能记录和可构建源码。
- 无触控回传，无音频传输。断线后不自动改用无线。
- 实际睡眠唤醒、受控物理拔插、VPN 策略切换、全屏复杂视频负载和不同热环境仍需专项验收。
- AOA 免 USB 调试、扫码发现、自动重连、广色域、10-bit、HDR 留待后续开发。
- Mac 使用 `CGVirtualDisplay` 私有 API，本机临时签名且未公证；Android 为支持 `run-as` 配对的调试构建。

长测后收紧了 Mac 开发签名：删除仅按应用标识匹配的要求，恢复默认代码哈希绑定，并撤销旧屏幕录制授权后重新授权。收尾时还修复了慢启动期间没有心跳的问题：收到 Pad 就绪消息后即开始保活，测试计时在采集启动成功后开始，避免把准备时间计为测试时间。注入延迟只存在于隔离测试构建，交付源码不含此延迟。最终构建另做 30 秒真实采集与静态桌面短测，长测与最终构建的二进制哈希分别记录；半小时数据不冒充修改后版本的长测结果。

交付目录 `benchmarks/` 保留原始 JSON；`system-checks.json` 记录验证项目与所测二进制 SHA-256。复测命令和统计定义在源码 README 与 `docs/PROTOCOL.md` 中。
'''
    (root / 'docs/VALIDATION.md').write_text(content.replace('![半小时的帧率、解码确认往返延迟和内存曲线](稳定性曲线.png)', '曲线文件位于同批交付的 `稳定性曲线.png`。'))
    (root / 'outputs/验证报告.md').write_text(content)
    (args.reports / 'summary.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
    with (args.reports / 'summary.csv').open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(results[0]))
        writer.writeheader()
        writer.writerows(results)
    print(root / 'outputs/验证报告.md')


if __name__ == '__main__':
    main()
