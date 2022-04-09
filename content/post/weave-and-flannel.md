---
title: "Weave 和 Flannel 的区别"
date: 2022-04-09T16:59:44+08:00
draft: false
---


这篇文章主要讨论 weave 和 flannel 各自怎么使用 vxlan 实现跨主机网络的情况。从网络设备、主机路由、IP管理、CNI实现、容器路由、vxlan发现几个角度来比较。


## 1. weave

### 有哪些网络设备

一个 bridge ，通常命名为 weave，会配一个 IP。用于挂载和容器成对的 veth。

一个 ovs 设备，命名为 datapath，没有配 IP。

一个 vtep 设备 vxlan-6784，负责封包和拆包，没有配 IP。

bridge 和 ovs 设备之间用一对 veth 连起来： vethwe-datapath 和  vethwe-bridge。

### 主机路由和网段划分

只有一条路由，所有 pod 是一个子网，不区分 node，IPAM 由weave 主机分配， weave cni 会调用 weave 服务获取 IP。

```
# 在 node 上执行 ip route 
10.32.0.0/12 dev weave  proto kernel  scope link  src 10.32.0.1
```

10.32.0.0/12 是该集群的 pod CIDR。

### CNI 阶段

kubelet 调用 weave-plugin 这个 cni 插件，通过 weave client 从 weave daemon 获取 ip（ip分配由weave管理），并在容器内配置网卡和 IP，并将网卡对应的 veth 连接到 weave bridge 上。

### 跨主机网络通信过程（如何区分目的 pod 在本机还是跨主机）

对于 src pod 内，需要发送三层分组时，首先查看路由表，然后通过 arp 寻找下一跳 IP 对应的 Mac 地址

```
# 在 pod 内执行 ip route
default via 10.46.0.0 dev eth0
10.32.0.0/12 dev eth0 proto kernel scope link src 10.46.0.8
```

会构造一个 arp 广播包，src mac 是本 pod 的地址，查询目的 pod 的 ip。这个广播包会通过 veth 对到达 weave bridge。这里分两种情况：

1. 假如目的 pod 是本机的，它也通过 veth 连接到 weave bridge 上，所以能收到 mac 广播，并响应 arp。

2. 同时 ，datapath 通过 vethwe-datapath 也能收到，datapath 也会把这个包通过 vxlan 封装，广播到所有的 node。目的 pod 通过相反的路径，收到 arp 广播，如果发现是自己的 IP，也可响应 arp 告知自己的 mac 地址（同样是，pod->veth pair-> weave bridge -> veth pair -> datapath -> vxlan 的路径）。 


src pod 得到 dst mac 地址，直接封装二层包发送数据。

在对端的 weave bridge 能抓到 arp 广播和响，非查询本机 pod 的 arp 也可以收到。 

```
# tcpdump -i weave arp
07:12:39.036901 ARP, Request who-has 10.40.0.9 tell 10.46.0.8, length 28
07:12:39.036923 ARP, Reply 10.40.0.9 is-at 8e:c5:12:0f:52:78, length 28
```

### datapath 原理

datapath 位于内核，1. 可以在内核直接转发数据，不需要经过内核态-用户态的复制（对比 weave 的Sleeve模式，通过 pcap 抓包到用户态转发性能更优） 2. 可以通过 ovs 控制器下发流表，灵活控制数据转发方向。

根据 weave 文档（[Misses and Flow Creation](https://github.com/weaveworks/weave/blob/master/docs/fastdp.md#misses-and-flow-creation)），weave 不会下发固定的流表，而是等 datapath 发生 miss，通过 misshandler 动态下发流表，告诉 datapath 怎么转发数据（[`dp.ConsumeMisses(fastdp)`](https://github.com/weaveworks/weave/blob/e3712152d2a0fe3bc998964c948e45bdf8ff6144/router/fastdp.go#L144)）。

这里主要涉及 vethwe-datapath 和 vxlan-6784 两个 port。

可以通过 ovs 的命令查看：

```
# sudo ovs-dpctl show -s
system@datapath:
        lookups: hit:667047 missed:30793 lost:3
        flows: 0
        masks: hit:1043797 total:0 hit/pkt:1.50
        port 0: datapath (internal)         # 内核的 datapath
        port 1: vethwe-datapath             # 与 weave bridge 相连的 veth
        port 2: vxlan-6784 (vxlan)          # vtep

# 也可以用以下命令查看触发的流表和网络包的情况
# sudo ovs-dpctl -m dump-flows datapath
# sudo ovs-dpctl-top 
```


## 2. flannel

### 有哪些网络设备

一个 bridge，通常命名为 cni0，会配 IP。用于挂载和容器成对的 veth。

一个 vtep，通常命名为 flannel.1，也会配 IP。



### 主机路由和网段划分

会有多条路由，有几个 node 就有几个路由。

一个 node 有一个子网，node 的子网分配由 kube-controller-manager 分配（也可以配置使用 etcd 的 lease 机制做 IPAM）。会保证一个node有一个不重叠的子网。

```
# 在 node 上执行 ip route
# 其他 node 的网段的路由
10.244.0.0/24 via 10.244.0.0 dev flannel.1 onlink
10.244.1.0/24 via 10.244.1.0 dev flannel.1 onlink
# 本机 pod 的路由，直接发到 cni0
10.244.2.0/24 dev cni0  proto kernel  scope link  src 10.244.2.1
```

10.244.0.0/16 是集群的 pod CIDR。从 pode CIDR 划分三个子网，10.244.0.0/24,10.244.1.0/24,10.244.2.0/24.

一般 10.244.0.0 是flannel.1 的 IP，10.244.0.1 是 cni0 的 IP。


### CNI 阶段

flannel使用一个flannel的cni插件（由kubelet调用），读 `/run/flannel/subnet.env`（flanneld 会把本机子网写在这里） ，获取本机的子网，并调用 bridge cni插件来配置网卡（创建network ns，创建veth pair，把veth pair 加到 cni bridge)，调用 host-local cni 插件来从本机子网中分配 pod ip

### 跨主机网络通信过程（如何区分目的 pod 在本机还是跨主机）

pod 内路由

```
# 在 pod 内执行 ip route
default via 10.244.2.1 dev eth0
10.244.0.0/16 via 10.244.2.1 dev eth0
10.244.2.0/24 dev eth0 proto kernel scope link src 10.244.2.46
```

这里就做出了区分，路由是最长前缀匹配，所以会先看目的地址是否是本机。因为本机pod都是一个子网，所以从 CIDR 就可以方便地区分出来。

1. 如果目的地址是本机，直接发送 arp 广播，源IP写的是src pod IP，要查询的地址是 dst pod IP 。这个 arp 广播会被所有通过veth pair连接到 cni0
 bridge 的网卡收到，也就是本机的 pod 都能收到，并相应 arp，告知 mac，继续往后的通信流程。
2. 如果目的地址不是本机，但属于 pod cidr 范围，会发送到 cni0 bridge 上。（也会 arp，但查询的是 10.244.2.1 的 IP，即 cni0 的 IP）

    2.1 IP 包到达 cni0 bridge，会查 node 路由表，根据 CIDR 决定下一跳 IP 和端口。下一跳是目的 pod 所在 node 的 flannel.1 的IP，发送的出口是本机的 flannel.1

    2.2 知道对端 vtep IP，但是不知道 mac，需要广播 arp。不过 flanneld 在这里做了手脚，直接在 arp 缓存里添加永久的 arp 记录，因为 flanneld 通过 kube-apiserver 交换信息，知道全局的路由拓扑。这时的二层包，src mac是本机 flannel.1 的 mac，dst mac是对端 flannel.1 的mac。vtep 把这个 mac封装成vxlan udp 包。

    2.3 接下来需要发送 udp 了，但是还不知道对端的 node ip在哪里，因为每个 node 只有一个物理网卡，或者说外部网卡，只有通过物理网卡的真实 IP 或者 mac 才能发送。这时会去查 flannel.1 的 fdb（fdb 存的是，发往某个mac的帧，应该从哪个端口出去），这里也是 flanneld 提前设置好的。通过对端 flannel.1. 的 mac 地址得到对端的 node ip。

    2.4 最终发送出去的 udp 包，src ip是本机物理网卡 ip，dst ip是对端主机物理网卡 ip， dst port 是6784，由内核监听的vxlan端口。udp 包里封装的 mac帧，src mac是本机 vtep mac，dst mac是对端 vtep mac。mac 帧的负荷，src ip 是src pod ip，dst ip是dst pod ip。（可以通过 `tcpdump -i [node物理网卡]` 看到）


## 3. weave 和 flannel 的区别

1. IPAM：weave是自己管理和分配，是一个大子网，不区分 node；flannel 是由 kube-controller-manager （分配 node 子网）和 ipam cni 分配（分配 pod ip）。
2. arp：weave：pod 的 arp 是可以广播到全网的，相当于是overlay的二层网络；flannel：arp只有本机的pod能获得，不能跨主机。
3. 容器内路由：weave只要是pod cidr 都直接广播 arp；flannel只有目的地址是本机 cidr 才会直接 arp，否则就发往 cni0，继续路由。
4. 主机路由：weave 不区分node 网段，只要是 pod cidr就发往 weave bridge ；flannel 会维护到每个node 的单独的路由。
5. vtep 的互相发现：weave 是通过 ovs 实现的；flannel是静态设置 arp、fdb和路由实现的。
6. cni 插件实现：weave 自己实现了 pod 网卡准备和 IPAM； flannel 主要还是用了标准的 bridge 和 ipam cni 插件。
7. 路由信息的交换：weave 是通过 tcp 和 gossip 协议来交换信息；flannel 依赖了 k8s 的 API 和 node 对象（信息写在 metadata.annotaion 中）。

## 4. Ref

[Kubernetes 网络学习：阅读 Flannel 源码](https://gobomb.github.io/post/learning-k8s-networking-reading-flannel-source/)


[weave docs](https://github.com/weaveworks/weave/blob/master/docs)


[ovs-dpctl - administer Open vSwitch datapaths](http://manpages.ubuntu.com/manpages/bionic/man8/ovs-dpctl.8.html)


[通过实验学习 Linux VETH 和 Bridge](https://gobomb.github.io/post/learning-linux-veth-and-bridge/)