---
title: "Wireguard 使用笔记"
date: 2019-10-07T16:40:14+08:00
draft: false
---

# Situation

公司和家庭在各自的内网里，并不互通，使用 wireguard 加一台处于公网的服务器，组成虚拟局域网，方便在家里访问公司内网或在公司访问家庭内网。

为什么不用 frp 或端口映射工具？ 需求之一是希望七层应用（包括 DNS）都不需要特别地设置；而端口映射作用在四层，每当有一个新的应用都得配置一遍。VPN 虚拟出来的网络处于网络层，路由规则一次性配好之后，就不需要再为了新的七层应用作额外的配置。

### 机器信息和 IP 规划

VPN 网段：`192.168.2.0/24`

bcc 的公网 IP（假设为）： `106.13.13.13`


机器 | 主机名 | VPN IP | 本地网卡 | 本地 IP
:-: | :-: | :-: | :-: | :-:
百度云机器 Ubuntu | bcc | `192.168.2.1/24` | eth0 | - | 
家庭内网机器 ArchLinux | home | `192.168.2.2/24` | wlp2s0 | `192.168.0.9/24`|
公司内网机器 CentOS | company | `192.168.2.3/24` | ens192 | `10.10.13.62/24`|
公司内网机器 CentOS | target | - | ens192 | `10.10.13.61/24`|



# Task

### 前提

1. 公网服务器（bcc）
2. 公司和家庭内网的机器能够访问公网（home 和 company 都可以访问到 bcc）
3. 公司内网网段和家庭内网网段不冲突

### 目标

能从家庭网络访问公司内部网络（使用 wireguard + iptables + route路由表实现），如在本文中就是要实现 home 能够访问到 target

### 说明

wireguard 主要用于建立 VPN，通过中间机器把两个网络的机器（网卡）组成一张虚拟局域网；

iptalbes 主要用来:
1. 放行转发的网络包； 
2. 做网络地址转换，保证在跨网络的时候数据包能够找到来时的路；

route 主要用来让 IP 数据包能够找到正确的网卡，发往正确的网关。

### 网络示意图

```


    +---------------------------------------+
    |                                       |                                        +---------------------------------------+
    |   +-----------------+   home network  |             +-----------+              |                                       |
    |   |                 |   192.168.0.0/24|             |           |              |  company network                      |
    |   |                 |                 |             |  bcc      |              |  10.10.13.0/24                        |
    |   | home            |                 |             |           |              |                                       |
    |   |                 |                 |             |eth0   wg0 |              |                                       |
    |   |                 |                 |             |        +  |              |    +------------------+               |
    |   |          wlp2s0 |                 |             +-----------+              |    |                  |               |
    |   |                 |                 |                      |                 |    | company          |               |
    |   |          wg0    |                 |                      |                 |    |                  |               |
    |   +-----------------+                 |                      |                 |    |                  |               |
    |               |                       |                      |                 |    | ens192           |               |
    |               |                       |                      |                 |    |                  |               |
    |               |                       |                      |                 |    | wg0              |               |
    |               |                       |                      |                 |    +------------------+               |
    |               |                       |       +----------------------+         |        |                              |
    |               |                       |       |                      |         |        |     +-----------------+      |
    |               |                       |       |  VPN                 |         |        |     |                 |      |
    |               |                       |       |  192.168.2.0/24      |         |        |     |   target        |      |
    |               +-------------------------------+                      +------------------+     |                 |      |
    |                                       |       |                      |         |              | ens192          |      |
    |                                       |       |                      |         |              |                 |      |
    +---------------------------------------+       |                      |         |              +-----------------+      |
                                                    +----------------------+         +---------------------------------------+
```

如图所示，home 和 company 的本地网卡分别处于不同的网络，但都各自通过虚拟网卡 wg0 组成了 VPN。这个 VPN 是逻辑上的，物理上包的走向还是通过本地网卡出去的，只不过 wireguard 帮我们做了封装和抽象（用 UDP 包封装 IP 包）。

# Action

配置过程分成三部分：1. 安装；2. 配置 VPN；3. 配置路由和转发规则。

详细过程旨在完整地再现配置的思路，方便读者了解网络的组成和数据包的流向，以及对 iptables、tcpdump 等工具的简单使用。在这个过程中没有进行任何永久性的操作，也就是说一旦机器重启配置就清空。在实际使用时还是需要将配置保存下来或者设置成开机启动，本文对这部分就暂不讨论了，配置原理和本文是一致的。

可到 [tldr 命令清单](#完整命令清单-tl-dr-版) 查看用到的所有命令。

### 1. 安装 wireguard

Ubuntu:

```
$ sudo add-apt-repository ppa:wireguard/wireguard
$ sudo apt-get update
$ sudo apt-get install wireguard
```

Arch:

```
$ sudo pacman -S wireguard-tools wireguard-arch
```

CentOS:

```
$ yum update -y
$ reboot # unless there were no updates
$ sudo curl -Lo /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
$ sudo yum install epel-release
$ sudo yum install wireguard-dkms wireguard-tools
```

### 2. 配置 VPN

1. 在 bcc 配置 wg 

```
# on bcc

# 生成私钥
$ wg genkey > private 

# 添加 wireguard 网卡 wg0
$ ip link add dev wg0 type wireguard

# 给 wg0 设置 IP 地址： 192.168.2.1
$ ip addr add 192.168.2.1/24 dev wg0

# 设置私钥
$ wg set wg0 private-key ./private

# 启动网卡
$ ip link set wg0 up

# 查看本节点的公钥：
$ wg
interface: wg0
  public key: OM5NlntS3l0hCBrrlvFGnVoThIniVICuulbszIQ0Lhs=
  private key: (hidden)
  listening port: 38371
```

2. 在 home 上配置 wg，并添加 bcc 节点

```
# on home

$ wg genkey > private
$ ip link add wg0 type wireguard
$ ip addr add 192.168.2.2/24 dev wg0
$ wg set wg0 private-key ./private
$ ip link set wg0 up
```

3. 添加 bcc 节点，使用第1步在 bcc 上生成的公钥，endpoint指定 bcc 的公网 IP 加端口号，allowed-ips 设置允许访问本机的 IP 段，persistent-keepalive 设定心跳时间秒数

```
# on home

$ wg set wg0 peer OM5NlntS3l0hCBrrlvFGnVoThIniVICuulbszIQ0Lhs= allowed-ips 192.168.2.0/24 endpoint  106.13.13.13:38371 persistent-keepalive 15

# 查看本节点的公钥
$ wg
interface: wg0
  public key: qqBQXePExrKBukMAVWId8Nv7IVMdbzLP2T2hljw2UCI=
  private key: (hidden)
  listening port: 52796

```

4. 在 bcc 上，添加 home 节点：

```
# on bcc

$ wg set wg0 peer qqBQXePExrKBukMAVWId8Nv7IVMdbzLP2T2hljw2UCI= allowed-ips 192.168.2.2/32 persistent-keepalive 15
```

4. 在 company 上配置 wg，并添加 bcc 节点

```
# on company

$ wg genkey > private
$ ip link add wg0 type wireguard
$ ip addr add 192.168.2.3/24 dev wg0
$ wg set wg0 private-key ./private
$ ip link set wg0 up
$ wg set wg0 peer OM5NlntS3l0hCBrrlvFGnVoThIniVICuulbszIQ0Lhs= allowed-ips 192.168.2.0/24 endpoint  106.13.13.13:38371 persistent-keepalive 15
$ wg
interface: wg0
  public key: +za3hn+HR84SrqiGjT95b49W5NVoFyEEIJPbMci6JUc=
  private key: (hidden)
  listening port: 49830
```

6. 在 bcc 上，添加 company 节点：

```
# on bcc

$ wg set wg0 peer +za3hn+HR84SrqiGjT95b49W5NVoFyEEIJPbMci6JUc= allowed-ips 192.168.2.3/32,10.10.13.0/24 persistent-keepalive 15
```

	这里 allowed-ips 添加多一个网段，目的是允许经过 bcc 的包访问公司内网 IP

5. 至此 VPN 的配置已经完成

```
# on bcc

$ wg
interface: wg0
  public key: OM5NlntS3l0hCBrrlvFGnVoThIniVICuulbszIQ0Lhs=
  private key: (hidden)
  listening port: 38371

peer: qqBQXePExrKBukMAVWId8Nv7IVMdbzLP2T2hljw2UCI=
  endpoint: 14.x.x.x:21511
  allowed ips: 192.168.2.2/32
  latest handshake: 1 minute, 9 seconds ago
  transfer: 1.90 MiB received, 3.65 MiB sent
  persistent keepalive: every 15 seconds

peer: bAZiJthnVFdroOyeCcKd8TNYM/2F2ql9sJEkiPNcBnk=
  endpoint: 117.x.x.x:46156
  allowed ips: 192.168.2.3/32,10.10.13.0/24
  latest handshake: 1 day, 2 hours, 15 minutes, 35 seconds ago
  transfer: 10.95 MiB received, 95.47 MiB sent
  persistent keepalive: every 15 seconds
```

此时的效果是，在 bcc、home、company 任意一台机器，ping 192.168.2.0/24 的 IP，都可以 ping 通。有了这个前提，我们就可以设置路由和转发规则了。

## 3. 写静态路由和转发规则

我们的目的是，在 home 能够直接访问 10.10.13.61。通过在 home 上 ping 公司内网机器，来一步步分析包的流向和一步步设置实现我们的目的


在 home 上先查看已有路由

```
# on home

$ ip r
default via 192.168.0.1 dev wlp2s0 proto dhcp src 192.168.0.9 metric 303 # 默认网关
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 # docker 网路的路由
192.168.0.0/24 dev wlp2s0 proto dhcp scope link src 192.168.0.9 metric 303 # 内网路由
192.168.2.0/24 dev wg0 proto kernel scope link src 192.168.2.2 # VPN 路由，在给 wg0 分配地址，在执行 ip link set wg0 up，系统会自动加这一条路由
```

尝试 ping：

```
# on home

$ ping 10.10.13.61 -c 1
PING 10.10.13.61 (10.10.13.61) 56(84) bytes of data.
```

首先，在 home 上，10.10.13.61 是没有对应路由规则的，发往这个地址的包默认会走默认网卡和默认网关，

```
# on home

# 在默认网卡上抓包，这个 IP 在这个网络里是不存在的
$ tcpdump -i wlp2s0 -nn icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wlp2s0, link-type EN10MB (Ethernet), capture size 262144 bytes
15:47:18.508559 IP 192.168.0.9 > 10.10.13.61: ICMP echo request, id 11180, seq 27, length 64
15:47:19.521895 IP 192.168.0.9 > 10.10.13.61: ICMP echo request, id 11180, seq 28, length 64
...
```


这不是我们期望的，我们希望他发往 wg0 网卡。

添加一条静态路由:

```
# on home

$ ip route add 10.10.13.0/24 via 192.168.2.1 dev wg0
```


此时，目的地址为 10.10.12.27 源地址为 192.168.2.2 的包已经通过 wg0 出去了。


```
# on home

$ tcpdump -i wg0 -nn icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
15:49:34.961873 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11285, seq 46, length 64
15:49:35.975153 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11285, seq 47, length 64
...
```

它的实际路径是，先通过隧道到达 bcc


```
# on bcc

$ tcpdump -i wg0  -nn
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
15:50:29.088012 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11285, seq 425, length 64
...

```


```
# on company

$ tcpdump -i wg0 icmp -nn
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
```


如果 bcc 没有开启转发，这个包在 bcc 这里，会被丢弃，company 抓不到任何包。

Linux 默认不允许转发，目的地址不是本机 IP 的包会被丢弃。开启了转发，目的地址不是本机 IP 的，会重新查路由表被转发到对应的目的。

开启转发(on bcc)并配置 iptables 转发规则：

```
# on bcc

# 临时生效：
$ echo "1" > /proc/sys/net/ipv4/ip_forward

# 永久生效，修改sysctl.conf：
$ net.ipv4.ip_forward = 1
$ sysctl -p

# 设置 iptables 的 filter 表 FORWARD 链，允许来自 wg0 和发往 wg0 的包通过
$ iptables -t filter -A FORWARD -i wg0 -j ACCEPT
$ iptables -t filter -A FORWARD -o wg0 -j ACCEPT
```

同样在 bcc 上设置路由，保证目的为 10.10.13.61 能找到正确的网卡：

```
# on bcc

$ ip r add 10.10.13.0/24 via 192.168.2.1 dev wg0
```

如果不设置路由，在 bcc 上抓包是这样的

```
# on bcc

$ tcpdump -i wg0  -nn
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
15:53:04.127719 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11285, seq 578, length 64
15:53:04.795808 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11501, seq 168, length 64

```

设置了路由，是这样的，同一个 ICNP 包会出现两次，说明有进有出：

```
# on bcc

$ tcpdump -i wg0  -nn
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
15:54:22.820680 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11501, seq 245, length 64
15:54:22.820710 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11501, seq 245, length 64
15:54:22.900694 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11430, seq 391, length 64
15:54:22.900718 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11430, seq 391, length 64
```


此时，company 终于收到来自 bcc 转发的 ICMP 包了：

```
# on company

$ tcpdump -i wg0 icmp -nn
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
15:51:59.758651 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11501, seq 104, length 64
15:51:59.832210 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11430, seq 250, length 64
```

通过 bcc 的转发和路由，这个包通过 wg 隧道到达 company 的 wg0 网卡。因为这个包的目的是 10.10.13.61，还需要 company 转发一次。

company 需要做的和在 bcc 上做的类似：1. 开启转发 2. 设置路由表

但这里有些许不同，我们可以跟着包的流向一步步设置

```
# on company

$ echo "1" > /proc/sys/net/ipv4/ip_forward

# 允许来自 wg0 的包被转发
$ iptables  -t filter  -A FORWARD -i wg0 -o ens192 -j ACCEPT

# 在 wg0 上抓包 on company
$ tcpdump -i wg0 -nn
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
15:37:47.638106 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11136, seq 151, length 64
...
```

目的地址是 10.10.13.61，因为是 company 所在网段，走默认路由、从默认网卡 ens192 出去即可，不需要再做额外设置。

此时，包已经到达 target 10.10.13.61 了。

在 10.10.13.61 上抓包可以验证设置 iptables 前，没有包到达，设置后有包到达。

```
# on target

$ tcpdump -i ens192 -nn icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on ens192, link-type EN10MB (Ethernet), capture size 262144 bytes
15:35:24.036458 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11136, seq 10, length 64
15:35:24.036576 IP 10.10.13.61 > 192.168.2.2: ICMP echo reply, id 11136, seq 10, length 64
...
```

可见 10.10.13.61 给了 ICMP 响应，但也有明显的问题，它回包的目的地址是 VPN 的地址，10.10.13.61 是没有此网段的路由的，所以它即使响应了，这个包也无法从原路径返回了。

为了解决这个问题，我们需要在 company 上做 NAT，把从 10.10.13.62 通过网卡 ens192 发往 10.10.13.0/24 网段的包，源地址都改成 10.10.13.62，这样回包的目的地址就是 10.10.13.62，可以路由回来。

```
# on company

$ iptables -t nat -A POSTROUTING -s 192.168.2.0/24 -o ens192 -j MASQUERADE
```

此时， 在 company 的 wg0、 ens192 和 target 的 ens192 上抓包

```
# on company

$ tcpdump -i wg0 icmp -nn
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
16:27:27.857949 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11915, seq 1, length 64
```

```
# on company 

$ tcpdump -i ens192 -nn icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on ens192, link-type EN10MB (Ethernet), capture size 262144 bytes
16:27:27.858039 IP 10.10.13.62 > 10.10.13.61: ICMP echo request, id 11915, seq 1, length 64
16:27:27.858319 IP 10.10.13.61 > 10.10.13.62: ICMP echo reply, id 11915, seq 1, length 64

```

```
# on target

$ tcpdump -i ens192 -nn icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on ens192, link-type EN10MB (Ethernet), capture size 262144 bytes
16:27:27.132347 IP 10.10.13.62 > 10.10.13.61: ICMP echo request, id 11915, seq 1, length 64
16:27:27.132427 IP 10.10.13.61 > 10.10.13.62: ICMP echo reply, id 11915, seq 1, length 64
```

可见数据包已经从company wg0 被转发到 company 的本地网卡 ens192，然后被发送到 target 的本地网卡，target 也回响应包了。

company ens192 拿到了响应包，但 wg0 却没有拿到回包，这是因为，到达 company ens192 的包，需要转发到 wg0，还需要一条规则：

```
# on company

iptables  -t filter  -A FORWARD  -i ens192 -o wg0 -j ACCEPT
```

这条规则实际上和上述的`$ iptables  -t filter  -A FORWARD -i wg0 -o ens192 -j ACCEPT`是一样的，只不过方向相反。

再次在 company 的 wg0、 ens192 和 target 的 ens192 上抓包:

```
# on company

$ tcpdump -i wg0 icmp -nn
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
16:30:25.443492 IP 192.168.2.2 > 10.10.13.61: ICMP echo request, id 11927, seq 1, length 64
16:30:25.444860 IP 10.10.13.61 > 192.168.2.2: ICMP echo reply, id 11927, seq 1, length 64
```

```
# on company

$ tcpdump -i ens192 -nn icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on ens192, link-type EN10MB (Ethernet), capture size 262144 bytes
16:30:25.443607 IP 10.10.13.62 > 10.10.13.61: ICMP echo request, id 11927, seq 1, length 64
16:30:25.444610 IP 10.10.13.61 > 10.10.13.62: ICMP echo reply, id 11927, seq 1, length 64
```

```
# on target

$ tcpdump -i ens192 -nn icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on ens192, link-type EN10MB (Ethernet), capture size 262144 bytes
16:30:24.718599 IP 10.10.13.62 > 10.10.13.61: ICMP echo request, id 11927, seq 1, length 64
16:30:24.718716 IP 10.10.13.61 > 10.10.13.62: ICMP echo reply, id 11927, seq 1, length 64
```

一切正常，符合预期。

同时，在 home 的 ping 终于拿到 61 的 ICMP 响应了。说明 IP 层已经打通。


尝试在 home ssh 到 target，可以成功：

```
# on home

$ ssh root@10.10.13.61
root@10.10.13.61's password:
```

经过完整设置后，从 home ping target 的过程如下：

1. 在 home 上，首先会查路由表，找到 10.10.13.61 应该走 wg0（请求包的源地址和目的地址是：`192.168.2.2 > 10.10.13.61`）
2. wg0 是 wireguard 虚拟出来的网卡，网络包的实际轨迹是：从 home 的 wg0 通过 home 的本地网卡（wlp2s0）发往 bcc 的公网IP（106.13.13.13），到达 bcc 的本地网卡再到 bcc 的 wg0。这个路径就是 wireguard 帮我们实现的隧道
3. bcc 从 wg0 拿到这个 ICMP 包，发现目的地址（10.10.13.61）不是本机的 IP（106.13.13.13），会根据路由表再次转发到 wg0
4. company 从 wg0 获得这个包，同样发现目的地址不是本机 IP，查路由表做转发，在包通过本地网卡（ens192）会做一次 NAT，即把源地址（192.168.2.2）改成本机网卡地址（10.10.13.62），此时请求包的源地址和目的地址是：`10.10.13.62 > 10.10.13.61` 
5. target 收到这个包，做出响应，响应包的源地址和目的地址与请求包是反过来的，所以它会被发回 company。响应包的源地址和目的地址是：`10.10.13.61 > 10.10.13.61`
6. 响应包回到 company，因为之前做了 NAT，会有记录，响应包的目的地址（10.10.13.62）会改回之前的源地址（192.168.2.2）。此时响应包的源地址和目的地址是：`10.10.13.61 > 192.168.2.2`
7. 检查路由表发现响应包应该走 wg0，即原路返回。home 上的 ping 程序就拿到了响应包。

实际上，company 在这里是充当了网关的角色。

请求包经过的网卡如下（响应包则是反过来）：

`home.wg0->(wg tunnel)->bcc.wg0->(forward)->bcc.wg0->(wg tunnel)->company.wg0->(forward)->(nat)->company.ens192->target.ens192`

### 完整命令清单（TL;DR 版）

1. 在每台机器上设置 wireguard 网卡

```
# on bcc
$ wg genkey > private 
$ ip link add dev wg0 type wireguard
$ ip addr add 192.168.2.1/24 dev wg0
$ wg set wg0 private-key ./private
$ ip link set wg0 up

# on home
$ wg genkey > private
$ ip link add wg0 type wireguard
$ ip addr add 192.168.2.2/24 dev wg0
$ wg set wg0 private-key ./private
$ ip link set wg0 up
$ wg set wg0 peer OM5NlntS3l0hCBrrlvFGnVoThIniVICuulbszIQ0Lhs= allowed-ips 192.168.2.0/24 endpoint  106.13.13.13:38371 persistent-keepalive 15

# on company
$ wg genkey > private
$ ip link add wg0 type wireguard
$ ip addr add 192.168.2.3/24 dev wg0
$ wg set wg0 private-key ./private
$ ip link set wg0 up
$ wg set wg0 peer OM5NlntS3l0hCBrrlvFGnVoThIniVICuulbszIQ0Lhs= allowed-ips 192.168.2.0/24 endpoint  106.13.13.13:38371 persistent-keepalive 15

# on bcc
$ wg set wg0 peer qqBQXePExrKBukMAVWId8Nv7IVMdbzLP2T2hljw2UCI= allowed-ips 192.168.2.2/32 persistent-keepalive 15
$ wg set wg0 peer +za3hn+HR84SrqiGjT95b49W5NVoFyEEIJPbMci6JUc= allowed-ips 192.168.2.3/32,10.10.13.0/24 persistent-keepalive 15
```

2. 在 home 设置路由

```
# on home
$ ip route add 10.10.13.0/24 via 192.168.2.1 dev wg0
```

3. 在 bcc 上设置

```
# on bcc
$ net.ipv4.ip_forward = 1
$ sysctl -p
$ iptables -t filter -A FORWARD -i wg0 -j ACCEPT
$ iptables -t filter -A FORWARD -o wg0 -j ACCEPT
$ ip r add 10.10.13.0/24 via 192.168.2.1 dev wg0
```  

4. 在 company 上设置

```
# on company
$ net.ipv4.ip_forward = 1
$ sysctl -p
$ iptables  -t filter  -A FORWARD -i wg0 -o ens192 -j ACCEPT
$ iptables -t nat -A POSTROUTING -s 192.168.2.0/24 -o ens192 -j MASQUERADE
$ iptables  -t filter  -A FORWARD  -i ens192 -o wg0 -j ACCEPT
```

# Result

通过 wireguard 成功组成了跨 nat 的 VPN；通过设置静态路由和 iptables，实现了跨网络包的转发。

通过 wireguard 的使用，可以对 VPN 有个大致的了解。首先，VPN 是点对点的网络，一般是在两个网络的网关上建立 VPN，在本文中，home 和 company 充当了各自网络的网关角色，分别和 bcc 建立点对点的连接；其次，VPN 是隧道，用 UDP（或其他协议，wiregard 是使用 UDP） 封装了三层的网络包。使用 VPN 的时候，在本地网卡上抓包，只能看到加密过的 UDP 包（或封装过的其他协议包），不是原始的网络层包。

