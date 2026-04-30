# 👻 Smart Balancer (智能流量特征伴随与对冲系统)

![Version](https://img.shields.io/badge/Version-V7.0-blue.svg)
![Bash](https://img.shields.io/badge/Language-Bash-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

**Smart Balancer** 是一款专为防范国内运营商（ISP）大流量及 PCDN 稽查而设计的“流量特征洗白引擎”。

针对中转前置机或代理节点天然产生的**“上下行极度对称 (1:1)”**这一致命特征，Smart Balancer 通过监听网卡底层数据，以毫秒级的响应速度，智能拉起国内大厂（腾讯、360 等）的极速商业 CDN 下载任务。强行将网卡总流量撕扯成符合正常家庭宽带特征的**“非对称模型”**（如下载:上传 = 1.5:1），让您的节点完美融于普通网民的赛博背景之中。

---

## ⚡ 核心架构与特性

- 🧮 **水池记账算法 (Token Bucket)**：彻底摒弃传统的瞬时网速跟随。无论您的代理流量多么细碎、突发，引擎都会将会计级“流量欠条”精确记录，并在后台静默还款，绝不遗漏 1KB 的特征伪装。
- 🔪 **防假死猎杀核心**：内置链路健康监控。一旦侦测到 HTTP 下载链路出现限速或假死（连续 6 秒 < 200KB/s），引擎将无情斩杀僵尸进程，并在 1 秒内强制切换备用极速节点，确保洗流永不断档。
- 🚀 **大厂黄金级 CDN 弹夹**：彻底抛弃容易 404 和被限速的开源系统镜像站。默认使用腾讯 QQ 浏览器、360 安全浏览器等**骨灰级静态 HTTP 安装包**，规避 TLS 握手开销，瞬时并发下载极速可达 **100MB/s+**。
- ⏱️ **时空轮换伪装逻辑**：支持“定时高危期潜伏”与“全天候 24/7 对冲”双模式；支持“每次随机换源”与“每日自动固定源”，最大程度模拟真实的国民级软件更新特征。
- 🎯 **纯净版物理雷达**：无乱码终端 UI，键入快捷命令即可呼出高频刷新的物理雷达，实时观赏流量欠账与引擎的狂暴对冲过程。

---

## 📦 一键极速部署

请使用 `root` 权限登录您的 Linux 服务器（如 Ubuntu / Debian / CentOS），并执行以下命令：

```bash
wget -O sb.sh [https://raw.githubusercontent.com/starshine369/smart_balancer/main/smart_balancer.sh](https://raw.githubusercontent.com/starshine369/smart_balancer/main/smart_balancer.sh) && bash sb.sh
