---
title: "使用 OpenSSH 建立 L2 和 L3 隧道"
date: 2020-01-09T12:05:28+08:00
draft: false
categories: [技术文章]
---

# 服务器环境

```
server：ubuntu，处于172.16.0.0/16网段，默认网卡是eth0，server处于公网
client：centos，处于10.10.13.0/24网段，默认网卡是ens192，client处于nat之后
```

# server端的配置

`vi /etc/ssh/sshd_config`

```
PermitRootLogin yes
PermitTunnel yes
```

# L3 Tunnel 配置过程

在client上执行

```
ssh -w 5:5 root@[server 公网ip] 
```

如果`-w`设置为`any`，会自动使用下一个可用的tun设备。

执行完该命令会进入到server中，client和server各自会创建一个link：`tun5`。

给server的VPN网卡配置地址和路由：

```
# 配置地址10.0.1.1
# 或者 ip address add 10.0.1.1/30 dev tun5
ifconfig tun5 10.0.1.1 netmask 255.255.255.252

# 启动网卡
ip link set tun5 up
# 配置到达10.10.13.0/24的路由
# 或者 
# ip route add 10.10.13.0/24 dev tun5
route add -net 10.10.13.0 netmask 255.255.255.0 dev tun5

# 开启转发
echo 1 > /proc/sys/net/ipv4/ip_forward 
iptables -t filter -A FORWARD -P ACCEPT

# 设置nat
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

在client：

```
# 配置地址10.0.1.2
# 或者 ip address add 10.0.1.2/30 dev tun5
ifconfig tun5 10.0.1.2 netmask 255.255.255.252

# 启动网卡
ip link set tun5 up
# 配置到达172.16.0.0/16的路由
# 或者 
# ip route add 172.16.0.0/16 dev tun5
route add -net 172.16.0.0 netmask 255.255.0.0 dev tun5

# 开启转发
echo 1 > /proc/sys/net/ipv4/ip_forward 
iptables -t filter -A FORWARD -P ACCEPT
# 设置nat
iptables -t nat -A POSTROUTING -o ens192 -j MASQUERADE
```

此时，在client可ping通172.16.0.0/16网段的机器，在server上可ping通10.10.13.0/24的机器。

当进程`root     28073 23865  0 17:40 pts/0    00:00:00 ssh -w 5:5 root@[server 公网ip]`被kill，连接就会断掉。


# L2 Tunnel 配置过程


安装`brctl`工具

```
# ubuntu
apt install bridge-utils
# centos
yum install brctl
```

建立连接：

```
# 参数 -o 需要在 -w 前面
ssh -o Tunnel=ethernet -w 6:6 root@[server 公网ip]
```

执行完该命令会进入到server中，在server和client执行`ip link`可以看到新创建了tap设备`tap6`。

在server上配置bridge `br0`，并把`tap6`加到`br0`中

```
# 添加 br0
brctl addbr br0
# 添加 tap6 到 br0 中
brctl addif br0 tap6
# 给 br0 添加 ip 地址
ip address add 10.0.1.1/30 dev br0
# 启动 br0 和 tap6
ip link set br0 up; ip link set tap6 up
```

在client上配置bridge `br0`，并把`tap6`加到`br0`中

```
# 添加 br0
brctl addbr br0
# 添加 tap6 到 br0 中
brctl addif br0 tap6
# 给 br0 添加 ip 地址
ip address add 10.0.1.2/30 dev br0
# 启动 br0 和 tap6
ip link set br0 up; ip link set tap6 up
```

在client通过`ip link`可以看到`br0`和`tap6`的mac地址是`9a:87:d2:12:8f:bd`

在server通过`ip link`可以看到`br0`和`tap6`的mac地址是`82:55:5b:75:e4:29`

在server通过`bridge fdb`可以看到server的mac转发表有client的记录（client的主机名是master）：

```
9a:87:d2:12:8f:bd dev tap6 master br0
```

在client通过`bridge fdb`可以看到client的mac转发表有server的记录：

```
82:55:5b:75:e4:29 dev tap6 master br0
```

或者通过`arp -a`查看arp缓存：

```
# on server
? (10.0.1.2) at 9a:87:d2:12:8f:bd [ether] on br0
# on client
? (10.0.1.1) at 82:55:5b:75:e4:29 [ether] on br0
```

在server端`arping -I br0 10.0.1.2`，同时在client `tcpdump -i br0 -n`可以看到arp请求和响应，可见此时二层是通的：

在 server 发起 arp 请求：
```
$ arping -I br0 10.0.1.2
ARPING 10.0.1.2 from 10.0.1.1 br0
Unicast reply from 10.0.1.2 [9A:87:D2:12:8F:BD]  8.453ms
Unicast reply from 10.0.1.2 [9A:87:D2:12:8F:BD]  9.330ms
Unicast reply from 10.0.1.2 [9A:87:D2:12:8F:BD]  9.682ms
```

在 client 抓包：
```
$ tcpdump -i br0 -n
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on br0, link-type EN10MB (Ethernet), capture size 262144 bytes
11:55:40.843929 ARP, Request who-has 10.0.1.2 (Broadcast) tell 10.0.1.1, length 28
11:55:40.843961 ARP, Reply 10.0.1.2 is-at 9a:87:d2:12:8f:bd, length 28
11:55:41.844165 ARP, Request who-has 10.0.1.2 (9a:87:d2:12:8f:bd) tell 10.0.1.1, length 28
11:55:41.844202 ARP, Reply 10.0.1.2 is-at 9a:87:d2:12:8f:bd, length 28
11:55:42.844422 ARP, Request who-has 10.0.1.2 (9a:87:d2:12:8f:bd) tell 10.0.1.1, length 28
11:55:42.844455 ARP, Reply 10.0.1.2 is-at 9a:87:d2:12:8f:bd, length 28
11:56:06.226079 IP6 fe80::8055:5bff:fe75:e429 > ff02::2: ICMP6, router solicitation, length 16
```


# Ref

https://linux265.com/course/3414.html

https://unix.stackexchange.com/questions/268690/for-some-reason-sudo-ssh-w-any-o-tunnel-ethernet-rootremote-creates-tun-dev

https://la11111.wordpress.com/2012/09/24/layer-2-vpns-using-ssh/
