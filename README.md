# wireguard-install

Linux 一键安装 WireGuard 节点脚本，安装完成后**直接输出 Clash Meta / Mihomo 可用的代理配置**。

基于 [angristan/wireguard-install](https://github.com/angristan/wireguard-install) 改造，去除了客户端管理菜单，聚焦"装好即用、配置即出"的场景。

## 支持的发行版

| 系统 | 版本 |
|---|---|
| Debian | 11 / 12 |
| Ubuntu | 20.04 / 22.04 / 24.04 |
| Fedora | 38+ |
| CentOS Stream / AlmaLinux / Rocky Linux | 8 / 9 |
| Oracle Linux | 8 / 9 |
| Arch Linux | rolling |
| Alpine Linux | 3.16+ |

> 不支持 OpenVZ / LXC（WireGuard 需要内核模块）。

## 快速开始

### 一键安装（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MainDotCpp/wireguard-install/main/wireguard-install.sh)
```

> 需要 root 权限。如果以普通用户运行，前面加 `sudo`：
> ```bash
> sudo bash <(curl -fsSL https://raw.githubusercontent.com/MainDotCpp/wireguard-install/main/wireguard-install.sh)
> ```

安装完成后，Clash 配置文件自动保存到 `/root/wg-clash.yaml`，同时在终端打印预览。

### 本地运行

```bash
# 下载脚本
curl -fsSL https://raw.githubusercontent.com/MainDotCpp/wireguard-install/main/wireguard-install.sh -o wireguard-install.sh
chmod +x wireguard-install.sh

# 零交互模式（推荐）：全部参数自动取默认值
bash wireguard-install.sh

# 交互模式：逐一确认每个参数
bash wireguard-install.sh --interactive

# 卸载
bash wireguard-install.sh --uninstall
```

## 输出文件

| 文件 | 说明 |
|---|---|
| `/etc/wireguard/wg0.conf` | 服务端配置 |
| `/etc/wireguard/params` | 参数缓存（重新运行脚本时自动加载） |
| `/root/wg0-client-<name>.conf` | 客户端原生 wg-quick 配置（备用） |
| `/root/wg-clash.yaml` | **Clash 配置（核心交付物）** |

## Clash 配置使用方法

安装完成后，`/root/wg-clash.yaml` 中的内容类似：

```yaml
proxies:
  - name: "WG-clash-abc123"
    type: wireguard
    server: "1.2.3.4"
    port: 54321
    ip: "10.66.66.2/32"
    ipv6: "fd42:42:42::2/128"
    private-key: "CLIENT_PRIVATE_KEY_BASE64"
    public-key: "SERVER_PUBLIC_KEY_BASE64"
    pre-shared-key: "PSK_BASE64"
    udp: true
    mtu: 1420
    dns:
      - "1.1.1.1"
      - "8.8.8.8"
    workers: 0
    remote-dns-resolve: true
    allowed-ips:
      - "0.0.0.0/0"
      - "::/0"
```

将上方内容复制到你的 Clash 配置文件的 `proxies:` 列表中，然后在 `proxy-groups` 里引用 `"WG-clash-abc123"` 即可。

## 环境变量（零交互模式下可自定义参数）

| 变量 | 说明 | 默认值 |
|---|---|---|
| `WG_PORT` | 服务端监听端口 | 随机 49152–65535 |
| `WG_IF` | WireGuard 接口名 | `wg0` |
| `WG_IPV4_SERVER` | 服务端 wg 内网 IPv4 | `10.66.66.1` |
| `WG_IPV6_SERVER` | 服务端 wg 内网 IPv6 | `fd42:42:42::1` |
| `WG_DNS_1` | 客户端 DNS 主 | `1.1.1.1` |
| `WG_DNS_2` | 客户端 DNS 备 | `8.8.8.8` |
| `WG_ALLOWED_IPS` | 客户端 AllowedIPs | `0.0.0.0/0,::/0` |
| `WG_NAME` | 客户端名称 | `clash-<随机 6 位>` |

### 示例：指定端口和名称

```bash
WG_PORT=51820 WG_NAME=mynode bash wireguard-install.sh
```

## 重新生成 Clash 配置

脚本检测到 WireGuard 已安装时，会自动新增一个客户端并输出新的 Clash YAML（5 秒后自动继续，或用 Ctrl-C 退出）：

```bash
bash wireguard-install.sh
# 或指定名称
WG_NAME=home-mac bash wireguard-install.sh
```

## 防火墙适配

- 检测到 `firewalld` 运行中：使用 `firewall-cmd` 添加规则，并通过 `PostUp` / `PostDown` 随接口生命周期管理。
- 未检测到 `firewalld`：通过 `iptables` PostUp/PostDown 注入 NAT + FORWARD 规则。
- IP 转发：写入 `/etc/sysctl.d/wg.conf`，重启后持久生效。

## 验证安装

```bash
# 检查 WireGuard 运行状态
wg show wg0

# 检查端口监听
ss -unlp | grep <端口号>

# 查看 Clash 配置
cat /root/wg-clash.yaml
```
