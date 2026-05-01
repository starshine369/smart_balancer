# 👻 Smart Balancer (智能流量特征伴随与对冲系统)

![Version](https://img.shields.io/badge/Version-V8.3-blue.svg)
![Bash](https://img.shields.io/badge/Language-Bash-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

**Smart Balancer** 是一款专为防范国内运营商（ISP）大流量及 PCDN 稽查而设计的“流量特征洗白引擎”。

针对中转前置机或代理节点天然产生的“上下行极度对称 (1:1)”这一致命特征，Smart Balancer 通过监听网卡底层数据，以毫秒级的响应速度，智能拉起国内大厂（腾讯、360 等）的极速商业 CDN 下载任务。强行将网卡总流量撕扯成符合正常家庭宽带特征的“非对称模型”（如下载:上传 = 1.5:1），让您的节点完美融于普通网民的赛博背景之中。

---

## ⚡ 核心黑科技与特性

- ♾️ **无尽双向水池账本 (Infinite Ledger)**：彻底摒弃传统的瞬时网速跟随。无论您的代理流量多么细碎、突发，引擎都会将会计级“流量欠条”精确记录。系统支持**无限结余池**，下多了变结余（免死金牌），欠多了再补齐，在宏观按月统计上，实现绝对 100% 精准的数学比例伪装。
- 🛡️ **物理级防挤占引擎 (QoS Yielding)**：您的业务拥有绝对的 First Class 优先级！实时监控物理网卡总带宽，一旦总负载触碰警戒线（如 85%），洗流进程将被内核级信号 (`kill -STOP`) 瞬间物理冻结，绝不抢占真实业务的 1KB 宽带。
- 🛌 **智能错峰洗流 (Time-Shifting)**：支持动态负载识别。在白天高峰期仅记账不洗流，等深夜或网卡上行极低（如 < 100KB/s）的闲时，再犹如幽灵般开闸，平稳洗白全天积压的特征欠款，实现“零打扰”对冲。
- 🚦 **平滑流控阀门 (Smooth Limiter)**：自带下载限速功能（如限制在 20MB/s）。告别 1000Mbps 极速拉流带来的瞬时超调和异常突刺，让洗流图谱看起来像极了一个人类正在匀速缓冲 4K 高清视频。
- 🔪 **防假死猎杀核心**：内置链路健康监控。一旦侦测到 HTTP 下载链路出现限速或假死（连续 6 秒 < 50KB/s），引擎将无情斩杀僵尸进程，并在 1 秒内强制切换备用大厂极速节点，确保洗流永不断档。
- 🧹 **幽灵日志自洁 (Auto Log-Rotation)**：全天候 24/7 守护且毫无痕迹。自带日志自洁切割功能，超出 2MB 自动截断，永远不爆盘，适配 512M 乞丐版超小口径 VPS。

---

## 📦 一键极速部署

请使用 `root` 权限登录您的 Linux 服务器（如 Ubuntu / Debian / CentOS），并执行以下命令（已内置国内 `ghproxy` 穿墙加速）：

```bash
wget -O sb.sh https://ghproxy.net/https://raw.githubusercontent.com/starshine369/smart_balancer/main/smart_balancer.sh && bash sb.sh
