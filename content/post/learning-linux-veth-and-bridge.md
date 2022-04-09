---
title: "通过实验学习 Linux VETH 和 Bridge"
date: 2019-09-17T01:07:13+08:00
draft: false
categories: [技术文章]
---


## 背景

docker 容器的网络，以及 flannel 网络的实现都用到了 VETH 和 Bridge 这两种虚拟设备。大致原理是在主机创建一个 Bridge，每当一个新的容器创建，就创建一对 VETH，一端连接到主机的 Bridge，另一端连接到容器命名空间里，作为容器的默认网卡，并将容器的默认路由设置为 Bridge。

本文将用 Linux 的相关命令，模拟上述网络创建的过程，并通过实验和抓包对原理进行验证，加深对容器和 Linux 网络的理解。

## 概念

VETH（virtual Ethernet）：是 Linux 内核支持的一种虚拟网络设备，表示一对虚拟的网络接口，VETH 对的两端可以处于不同的网络命名空间，所以可以用来做主机和容器之间的网络通信。

Bridge：Bridge 类似于交换机，用来做二层的交换。可以将其他网络设备挂在 Bridge 上面，当有数据到达时，Bridge 会根据报文中的 MAC 信息进行广播、转发或丢弃。

Namespace：是 Linux 提供的一种内核级别环境隔离的方法。不同命名空间下的资源集合无法互相访问。

## 实验环境：


	root@ubuntu:~# cat /proc/version
	Linux version 4.4.0-38-generic (buildd@lgw01-58) (gcc version 5.4.0 20160609 (Ubuntu 5.4.0-6ubuntu1~16.04.2) ) #57-Ubuntu SMP Tue Sep 6 15:42:33 UTC 2016


网卡名称和 IP 地址为`ens160 10.10.12.27/24`

## 网络拓扑示意图

```
                           +------------------------+
                           |                        | iptables +----------+
                           |  br01 192.168.88.1/24  |          |          |
                +----------+                        <--------->+ ens160   |
                |          +------------------+-----+          |          |
                |                             |                +----------+
           +----+---------+       +-----------+-----+
           |              |       |                 |
           | br-veth01    |       |   br-veth02     |
           +--------------+       +-----------+-----+
                |                             |
+--------+------+-----------+     +-------+---+-------------+
|        |                  |     |       |                 |
|  ns01  |   veth01         |     |  ns02 |  veth01         |
|        |                  |     |       |                 |
|        |   192.168.88.11  |     |       |  192.168.88.12  |
|        |                  |     |       |                 |
|        +------------------+     |       +-----------------+
|                           |     |                         |
|                           |     |                         |
+---------------------------+     +-------------------------+


```

br01 是一个 bridge，连接两个 veth，两个 veth 的另一端分别在另外两个 namespace 里。ens160 是宿主机对外的网卡，namespace 对外的包会经过 snat 从宿主机网卡出去。

## 实验过程

1. 设置 bridge 

	创建 bridge：
		
		$ brctl addbr br01
			

	
	启用 bridge

		 $ ip link set dev br01 up
	
	
	给 bridge 分配 IP 地址

		 $ ifconfig br01 192.168.88.1/24 up

2. 创建 namespace

	创建两个 ns：ns01、ns02
	
		
		$ ip netns add ns01
		$ ip netns add ns02
		$ ip netns list   # 查看创建的 ns
		ns02
		ns01
		

3. 设置 veth pair

	创建两对 veth
	
	
		$ ip link add veth01 type veth peer name br-veth01
		$ ip link add veth02 type veth peer name br-veth02
	
	
	将其中一端的 veth(br-veth01 / br-veth02) 挂到默认命名空间的 bridge(br01)下面
	
	
		$ brctl addif br01 br-veth01
		$ brctl addif br01 br-veth02
	
	
	查看 bridge 下挂的 veth
	
	
		$ brctl show
		bridge name	bridge id		STP enabled	interfaces
		br01		8000.1e72c41f55ab	no		br-veth01
												br-veth02
		
	
	启动这两个 veth
	
	
		$ ip link set dev br-veth01 up
		$ ip link set dev br-veth02 up
	 
	
	将另一端 veth 分配给两个上一步创建好的两个 ns(ns01 / ns02)
	
	
		$ ip link set veth01 netns ns01
		$ ip link set veth02 netns ns02
	
	
	通过 `ip netns exec [ns] [command]` 命令可以在特定的网络命名空间里执行命令
	
	查看命令空间里的网络设备：
	
	
		$ ip netns exec ns01 ip a
		1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1
			link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
		34: veth01@if33: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN group default qlen 1000
			link/ether 32:29:09:32:c5:91 brd ff:ff:ff:ff:ff:ff link-netnsid 0
	
	
	可以看到刚刚被我们加进来的 veth01，此时还没有 IP 地址
	
	给两个命名空间的 veth 设置 IP 地址和默认路由，默认网关设置为 bridge 的 IP：
	
	
		$ ip netns exec ns01 ip link set dev veth01 up
		$ ip netns exec ns01 ifconfig veth01 192.168.88.11/24 up
		$ ip netns exec ns01 ip route add default via 192.168.88.1
		
		$ ip netns exec ns02 ip link set dev veth02 up
		$ ip netns exec ns02 ifconfig veth02 192.168.88.12/24 up
		$ ip netns exec ns02 ip route add default via 192.168.88.1
	
	
	此时再看 ns01 的 veth01 已经被分配了 IP
	
		$ ip netns exec ns01 ip a
		1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1
			link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
		34: veth01@if33: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state LOWERLAYERDOWN group default qlen 1000
			link/ether 32:29:09:32:c5:91 brd ff:ff:ff:ff:ff:ff link-netnsid 0
			inet 192.168.88.11/24 brd 192.168.88.255 scope global veth01
			valid_lft forever preferred_lft forever
	

4. 不同 ns 互相 ping 并抓包

	从 ns01 里 ping ns02，同时在默认 ns 里用 tcpdump 在 br01 bridge 上抓包：
	
	ping:
	
	
		$ ip netns exec ns01 ping 192.168.88.12 -c 1
		PING 192.168.88.12 (192.168.88.12) 56(84) bytes of data.
		64 bytes from 192.168.88.12: icmp_seq=1 ttl=64 time=0.116 ms
		
		--- 192.168.88.12 ping statistics ---
		1 packets transmitted, 1 received, 0% packet loss, time 0ms
		rtt min/avg/max/mdev = 0.116/0.116/0.116/0.000 ms
	
	
	抓包：
	
	
		$ tcpdump  -i br01 -nn
		tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
		listening on br01, link-type EN10MB (Ethernet), capture size 262144 bytes
		15:17:57.592785 IP 192.168.88.11 > 192.168.88.12: ICMP echo request, id 17158, seq 1, length 64
		15:17:57.592868 IP 192.168.88.12 > 192.168.88.11: ICMP echo reply, id 17158, seq 1, length 64
	
	
	反之在 ns2 ping ns1 也是通的。

5. 在 ns01 里执行 arp

	
		$ ip netns exec ns01 arp
		Address                  HWtype  HWaddress           Flags Mask            Iface
		192.168.88.12            ether   1a:43:9a:b0:31:5e   C                     veth01
		192.168.88.1             ether   1e:72:c4:1f:55:ab   C                     veth01
	
	
	可以看到获取到的 MAC 地址是正确的：
	
	
		$ ip link
		...
		32: br01: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000
			link/ether 1e:72:c4:1f:55:ab brd ff:ff:ff:ff:ff:ff
		...
		
		$ ip netns exec ns02 ip link
		1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN mode DEFAULT group default qlen 1
			link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
		36: veth02@if35: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000
			link/ether 1a:43:9a:b0:31:5e brd ff:ff:ff:ff:ff:ff link-netnsid 0
	

6. 从 ns02 ping 外网地址

	
		$ ip netns exec ns02 ping 114.114.114.114
		PING 114.114.114.114 (114.114.114.114) 56(84) bytes of data.
		^C
		--- 114.114.114.114 ping statistics ---
		20 packets transmitted, 0 received, 100% packet loss, time 19151ms
	
	
	发现 ping 不通，继续抓包：
	
	
		$ tcpdump  -i br01 -nn
		tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
		listening on br01, link-type EN10MB (Ethernet), capture size 262144 bytes
		15:23:18.662300 IP 192.168.88.12 > 114.114.114.114: ICMP echo request, id 17919, seq 13, length 64
		15:23:19.669940 IP 192.168.88.12 > 114.114.114.114: ICMP echo request, id 17919, seq 14, length 64
		
		$ tcpdump  -i ens160 -nn  host 114.114.114.114
		tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
		listening on ens160, link-type EN10MB (Ethernet), capture size 262144 bytes
		15:41:59.533624 IP 192.168.88.12 > 114.114.114.114: ICMP echo request, id 20729, seq 1, length 64
		15:42:00.549989 IP 192.168.88.12 > 114.114.114.114: ICMP echo request, id 20729, seq 2, length 64
	
	
	
	发现只有出去的没有回来的包。原因应该是源地址是私有地址，发回来的包目的地址是私有地址的话会被丢弃，解决办法是做一下源 nat
	
	
		iptables -t nat -A POSTROUTING -s 192.168.88.0/24 -j MASQUERADE
	
	
	再次 ping 则可以 ping 通
	
	
		$ tcpdump  -i ens160 -nn  host 114.114.114.114
		...
		15:45:09.815939 IP 10.10.12.27 > 114.114.114.114: ICMP echo request, id 21211, seq 1, length 64
		15:45:09.844922 IP 114.114.114.114 > 10.10.12.27: ICMP echo reply, id 21211, seq 1, length 64
		...
		
		$ tcpdump  -i br01 -nn -vv
		...
		15:45:52.507058 IP (tos 0x0, ttl 64, id 24952, offset 0, flags [DF], proto ICMP (1), length 84)
			192.168.88.12 > 114.114.114.114: ICMP echo request, id 21315, seq 1, length 64
		15:45:52.535156 IP (tos 0x0, ttl 82, id 4450, offset 0, flags [none], proto ICMP (1), length 84)
			114.114.114.114 > 192.168.88.12: ICMP echo reply, id 21315, seq 1, length 64
		...
	
	
	可以看到，从 ens160 出去到外网的包，source IP 变成了外网网卡的 IP


7. 清理

	
		$ ip netns del ns01
		$ ip netns del ns02
		$ ifconfig br01 down
		$ brctl delbr br01
		$ iptables -t nat -D POSTROUTING -s 192.168.88.0/24 -j MASQUERADE
	



## 遇到的问题

设置完 brige 和 veth 之后，从 ns01 ping 不通 ns02 的网卡。在 bridge 能抓到`ICMP echo request`却没有`ICMP echo reply`，ns02 内没有抓到包。

宿主机是否开启转发，若开启了转发，iptalbes 规则是否有问题。`iptables -S | less`检查规则。

我在实验的时候因为主机上安装了 docker，FORWARD 链默认策略被 docker 设置成 drop。从 ns01 发出的 ICMP 报文是会被丢弃的。

解决方法是修改 FORWARD 的默认策略为 ACCEPT 放行：


	iptables -P FORWARD ACCEPT


## 总结

1. 涉及到的网络主要在二层和三层，需要对二层三层网络原理和协议比较熟悉。

2. 常用 Linux 网络命令，如 `ip` / `iptables` / `brctl` / `tcpdump` 等，也是需要掌握的，对于分析和定位网络问题很有帮助。这些命令本质上也是去 call 内核的系统调用，所以同样也可以用 go 或者 C 语言编程实现类似的功能。

## 参考

[Linux Switching – Interconnecting Namespaces](http://www.opencloudblog.com/?p=66)

[Using network namespaces and a virtual switch to isolate servers](https://ops.tips/blog/using-network-namespaces-and-bridge-to-isolate-servers/)

[Linux 上的基础网络设备详解](https://www.ibm.com/developerworks/cn/linux/1310_xiawc_networkdevice/)
