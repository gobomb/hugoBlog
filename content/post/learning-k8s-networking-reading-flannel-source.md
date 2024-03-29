---
title: "Kubernetes 网络学习：阅读 Flannel 源码"
date: 2019-09-09T18:59:32+08:00
draft: false
categories: [技术文章]
---


# 1. 背景：k8s 网络的介绍
 
k8s 的网络分几个层面：pod 网络、service 网络、node 网络。pod 网络一般由 flannel、weave、calico 这些 CNI 插件创建和维持，service 网络一般由 kube-proxy 通过操作 node 机器的 iptables 来维持，node 网络来自物理机或虚拟机层面的配置。

本文讨论的重点和范围是 pod 网络。

k8s 的 pod 网络有如下假设:

1. 每个 pod 有单独的 IP，所有 pod 都处于一张扁平的、可以互相 ping 通的网络上，即使 pod 处于不同的 node/虚拟机/宿主机上面。
2. 一个 pod 的所有容器共享一个网络空间（网卡和IP）

为了让 pod 网络变得平坦，一般有两种方式：

1. 使用 overlay 网络；
2. 使用路由协议（BGP）

overlay 是建立在实际物理网络上的一张虚拟逻辑网络，用二层、三层或四层协议来封装 pod 二层数据帧，与 VPN 有些类似，由于存在封包和拆包的过程，性能会有所损耗，flannel使用这种方式；使用路由协议，则 pod 和物理网络共同处于一张大三层网络，calico 使用这种方式。

本文将通过分析 [flannel 源码(v0.11.0)](https://github.com/coreos/flannel/tree/ecb6db314e40094a43144b57f29b3ec2164d44c9) 来学习 pod 网络的形成。

## 术语说明

本文假设读者对 k8s 的一些概念有所了解，对计算机网络二层和三层协议有基本的认识。

在这里对一些术语作一些简单的解释：

pod：k8s 调度的最小单位，里面有一个或者一组容器 

node：k8s 里的工作节点，一般是一台传统的物理机或者虚拟机，上面可以跑多个 pod

daemonset：可以理解成一种特殊的 pod， 保证每台 node 上都保证会有一个 pod

overlay 网络：是建立在实际物理网络上的一张虚拟逻辑网络，一般会用隧道（tunnle）协议（VxLAN、ipip等）实现

VXLAN（Virtual eXtensible Local Area Network） ：是一种封装或 overlay 网络协议，使用三层协议封装二层数据帧，由Linux内核实现

VTEP（VXLAN Tunnel Endpoints）：VxLAN 网络的边缘设备，用来进行 VxLAN 报文的处理（封包和解包）

veth: 用来连接不同命名空间的网络设备，可以反转数据流方向

bridge： Linux内核实现的虚拟交换机，可以连接其他的二层设备

BGP：边界网关协议，用来实现自治系统间的域间路由

CNI（容器网络接口）：CNI 是 CNCF 旗下的项目，规定了分配容器网络的一些列接口和二进制可执行文件。在 `/etc/cni/net.d`会存放 CNI 插件的配置文件，在 `/opt/cni/bin/`下会存放 CNI 插件的二进制文件，可以使用这些二进制创建网络设备、分配 IP 等。插件需要实现 CNI，由 kubelet 调用。 

# 2. flannel 做了什么

在安装 k8s 的时候， flanneld 会以 daemonset 的方式部署到集群内。flanneld 通过 watch-list 机制连接 kube-apiserver 监听 node 的变化，然后做一些相关的配置：配置具体封包/拆包的后端协议，本文是 VxLAN ；配置 iptables、路由规则、ARP 缓存、MAC 地址转发表等等，来规定 VxLAN 封包如何流动。

pod 网络的网段是 `10.244.0.0/16`，flannel 会分别给每台 node 上的 pod 分配 10.244.0.0/16 下的子网，比如 master 分配 `10.244.0.1/24`，第一台 node 分批 `10.244.1.1/24` 以此类推。

接下来会通过通过 flanneld 的源代码，结合具体的环境，做一些分析和学习。

## 集群环境说明

本文基于通过 kubeadm 1.15.3 安装的 k8s 集群，版本和节点信息如下：

```
$ kubectl version
Client Version: version.Info{Major:"1", Minor:"14", GitVersion:"v1.14.3", GitCommit:"5e53fd6bc17c0dec8434817e69b04a25d8ae0ff0", GitTreeState:"clean", BuildDate:"2019-06-06T01:44:30Z", GoVersion:"go1.12.5", Compiler:"gc", Platform:"linux/amd64"}
Server Version: version.Info{Major:"1", Minor:"15", GitVersion:"v1.15.3", GitCommit:"2d3c76f9091b6bec110a5e63777c332469e0cba2", GitTreeState:"clean", BuildDate:"2019-08-19T11:05:50Z", GoVersion:"go1.12.9", Compiler:"gc", Platform:"linux/amd64"}


[root@master ~]# kubectl get node -o wide
NAME     STATUS   ROLES    AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                KERNEL-VERSION               CONTAINER-RUNTIME
master   Ready    master   17d   v1.15.3   10.10.13.61   <none>        CentOS Linux 7 (Core)   3.10.0-957.21.2.el7.x86_64   docker://18.9.6
node02   Ready    <none>   17d   v1.15.3   10.10.13.63   <none>        CentOS Linux 7 (Core)   3.10.0-862.el7.x86_64        docker://18.9.6
node01   Ready    <none>   33m   v1.15.3   10.10.13.62   <none>        CentOS Linux 7 (Core)   3.10.0-862.el7.x86_64        docker://19.3.2
```

使用 go-template 输出每个节点分配到的网段：

```
$ kubectl get node  -o go-template='{{range .items}} {{.metadata.name}} {{.spec.podCIDR}} {{end}}'
 master 10.244.0.0/24  node02 10.244.2.0/24  node01 10.244.4.0/24
```

## flanneld 源码阅读

flanneld 源代码仓库地址在：https://github.com/coreos/flannel ，代码大致流程如下：

1. 查找外部网卡 `extIface, err = LookupExtIface("", "")`
2. 建立 SubnetManager

    子网管理器是一个 interface ,用于获取子网。有两个实现，基于 k8s api 的 kubeSubnetManager，和基于 etcd 并由 flannel 管理的 LocalManager.这里描述的是 kubeSubnetManager 的流程。

    ```
    type Manager interface {
        GetNetworkConfig(ctx context.Context) (*Config, error)
        AcquireLease(ctx context.Context, attrs *LeaseAttrs) (*Lease, error)
        RenewLease(ctx context.Context, lease *Lease) error
        WatchLease(ctx context.Context, sn ip.IP4Net, sn6 ip.IP6Net, cursor interface{}) (LeaseWatchResult, error)
        WatchLeases(ctx context.Context, cursor interface{}) (LeaseWatchResult, error)

        Name() string
    }
    ```

    2.1 初始化 clientset
    
    2.2 获取 node name
    
    2.3 读取 net-conf `/etc/kube-flannel/net-conf.json`

    ```
    # cat /etc/kube-flannel/net-conf.json
    {
      "Network": "10.244.0.0/16",
      "Backend": {
        "Type": "VxLAN"
      }
    }
    ```

    2.4 建立 nodeInformer，并开始监听 node 事件；事件放入 events channel 中

3. 捕捉 SIGTERM 信号
4. 建立 BeckendManager，SubnetManager 会被传给 BeckendManager, 调用方法 befunc 初始化后端网络

    会有多种 backend： VxLAN、udp、ipip、wireguard 等。这里主要以 VxLAN 为例子。

	4.1 创建VxLAN后端：传入SubnetManager和外部网卡

	4.2 注册VxLAN网络 RegisterNetwork
    
	- 创建 VxLAN 设备 flannel.1  `dev, err := newVXLANDevice(&devAttrs)`

   - 向 subenetManager 申请租约 `lease, err := be.subnetMgr.AcquireLease(ctx, subnetAttrs)`；给 node 添加 annotations

	- 给 VxLAN 设备设置 32 位的网段

5. 设置 ipMasq，修改 iptables 规则(POSTROUTING chain)

    ```
     # 于 node02（10.10.13.62)查看 iptables 规则
     # $ iptables -t nat -S 
    ... 
    -A POSTROUTING -s 10.244.0.0/16 -d 10.244.0.0/16 -j RETURN
    -A POSTROUTING -s 10.244.0.0/16 ! -d 224.0.0.0/4 -j MASQUERADE
    -A POSTROUTING ! -s 10.244.0.0/16 -d 10.244.2.0/24 -j RETURN
    -A POSTROUTING ! -s 10.244.0.0/16 -d 10.244.0.0/16 -j MASQUERADE
    ...
    ```

6. 写 subnet file `/run/flannel/subnet.env`

    ```
    # 于 node02（10.10.13.62) 上的 flannel pod 内查看该文件
    # cat /run/flannel/subnet.env
    FLANNEL_NETWORK=10.244.0.0/16
    FLANNEL_SUBNET=10.244.2.1/24
    FLANNEL_MTU=1450
    FLANNEL_IPMASQ=true
    ```

7. 启动beckend 	`bn.Run(ctx)`

    7.1 从 subnetManager.Events （2.4的channel）获取事件
    
    7.2 处理事件：添加/删除 arp 记录；添加/删除 fdb（mac地址转发表）;添加/删除路由

这一整个过程就是路由同步、下发的过程。

## flannel 二进制做了什么

在 node 的 `/opt/cni/bin` 目录下还有一个 [flannel plugin 二进制](https://github.com/containernetworking/plugins/tree/master/plugins/meta/flannel)，由 kubelet 在创建单个 pod 的时候调用，将读取 flanneld 产生的 `/run/flannel/subnet.env`，生成一系列配置文件，写入 `/var/lib/cni/flannel/[pod id]`，然后将生成的配置作为参数调用另一个 CNI plugin 二进制 [bridge](https://github.com/containernetworking/plugins/tree/master/plugins/main/bridge)

bridge 二进制第一次运行的时候会在 node 上生成一个 Linux bridge 设备，默认名字是 `cni0`。这个 bridge 就是一个虚拟交换机，新生成的 pod 网卡会通过 veth 设备连接到这个 bridge 上面。

bridge 每次被调用的时候，会给 pod 创建 veth，将 veth 连接到 cni0，并且调用  host-local 从本机 subnet 中分配 ip。

几个跟 flannel CNI 有关的文件或目录：

`/etc/cni/net.d/10-flannel.conf`  flannel CNI 的配置文件。

`/var/lib/cni/flannel` 这个目录下放的是 flannel 每次调用 bridge 用到的配置，文件名是 `io.kubernetes.sandbox.id` （通过docker inspect [container id] 可以看到）。

`/var/lib/cni/networks/cbr0`  这个目录下放的是 host-local CNI 分配的 IP，文件名为分配的容器 IP，文件内容为`io.kubernetes.sandbox.id`。


## node 子网信息从哪里来

当 kube-controller-manager 设置了 allocate-node-cidrs 和 cluster-cidr 参数时，kube-controller-manager 会为每个 node 确定 pod ip 范围。flanneld 刚启动时，在 RegisterNetwork (调用 `kubeSubnetManager.AcquireLease`)中获取当前 node 的 Spec.PodCIDR，并把需要的一些信息写入到 node 的 annotation。子网信息再写入到 /run/flannel/subnet.env （`main.WriteSubnetFile`），由 flannel CNI 读取，用于分配 pod ip。

另外，也可以配置成子网不由 k8s 分配，将 kube-subnet-mgr 参数置为 false 就是利用 etcd 来管理。


## flannel 网络示意和解析

下面我们结合 pod 网络的示意图来解读一下网络数据包的流向。

```
                                                                                                                                                                                                +
                                                                                                |
                                                                                    overlay     |   underlay
                                                                                                |
                                                                                                |
+---------------------------------------------------------------------------------------------------------------------+
|                                                                                               |                     |
|  node02                                                                                       |                     |
|                                                                                               |                     |
|                                                                                               |                     |
|        +--------------------+                                                                 |                     |
|        |  pod01             |                                                                 |                     |
|        |  10.244.2.48       |          +-----------------+                                    |                     |
|        |                    |          |                 |                                    |                     |
|        |                    +----------+  veth01         +----|   +-----------+               |                     |
|        |                    |          |                 |    |   |           |       +-------+------+  +-----------+
|        +--------------------+          +------------------    +---+           |       |              |  |           |
|                                                                   |           +-------+              +--+           +----------------------------------------+
|        +--------------------+                                     |   cni0    |       |  flannel.1   |  | ens192    |                                        |
|        |  pod02             |                                 +---+ 10.244.2.1/24     |  10.244.2.0/32  | 10.10.13.63/24                                     |
|        |                    |          +-----------------+    |   |           |       +-------+------+  +-----------+                                        |
|        |                    |          |                 |    |   +-----------+               |                     |                                        |
|        |                    +----------+  veth02         +----|                               |                     |                                        |
|        |                    |          |                 |                                    |                     |                                        |
|        +--------------------+          +------------------                                    |                     |                                        |
|                                                                                               |                     |                                        |
|                                                                                               |                     |                                        |
|                                                                                               |                     |                                        |
+---------------------------------------------------------------------------------------------------------------------+                                        |
                                                                                                |                                             +--------------+ |
                                                                                                |                                             |              | |
                                                                                                |                                             |              | |
                                                                                                |                                             | VxLAN packet(L3)
                                                                                                |                                             |              | |
+---------------------------------------------------------------------------------------------------------------------+                       |              | |
|                                                                                               |                     |                       +--------------+ |
|  node01                                                                                       |                     |                                        |
|                                                                                               |                     |                                        |
|                                                                                               |                     |                                        |
|        +--------------------+                                                                 |                     |                                        |
|        |  pod01             |                                                                 |                     |                                        |
|        |  10.244.4.2        |          +-----------------+                                    |                     |                                        |
|        |                    |          |                 |                                    |                     |                                        |
|        |                    +----------+  veth01         +----|   +-----------+               |                     |                                        |
|        |                    |          |                 |    |   |           |       +-------+-------+   +---------+                                        |
|        +--------------------+          +------------------    +---+           |       |               |   |         |                                        |
|                                                                   |           +-------+               +---+         +----------------------------------------+
|        +--------------------+                                     |   cni0    |       |  flannel.1    |   | ens192  |
|        |  pod02             |                                 +---+   10.244.4.1/24   |  10.244.4.0/32|   | 10.10.13.62/24
|        |                    |          +-----------------+    |   |           |       +-------+-------+   +---------+
|        |                    |          |                 |    |   +-----------+               |                     |
|        |                    +----------+  veth02         +----|                               |                     |
|        |                    |          |                 |                                    |                     |
|        +--------------------+          +------------------                                    |                     |
|                                                                                               |                     |
|                                                                                               |                     |
|                                                                                               |                     |
+-----------------------------------------------------------------------------------------------+---------------------+



```

在 node02 上使用`ip link`可以看到以下几个二层设备：

```
ens192 # 本机的物理网卡
flannel.1 # flanneld 创建的 VxLAN 设备
cni0 # linux brige
vethbe310cc8@if3 # 连接容器网卡和cni0的veth设备
...
```


## 数据转发流程

通过一些命令辅助说明跨主机的网络包的轨迹：

1. 在 IP 为 `10.244.2.48` 的 pod 内，`ping 10.244.4.2`。
2. 数据包通过 veth 到达 cni0

    ```
    [root@node02 ~]# brctl show
    bridge name	bridge id		STP enabled	interfaces
    cni0		8000.569a2f1ad085	no		veth95375d8f
                                                            vethb7b823f5
                                                            vethbe310cc8
                                                            vethce9ecc40
    docker0		8000.024210860cd5	no
    ```

    从上面的结果可以看到，cni0 上桥接了四个 veth，每个 veth 的另一端都是一个 pod 网卡。

3. 根据路由规则，数据包被路由到 `10.244.4.0`
    
    ```
    [root@node02 ~]# ip route
    default via 10.10.13.1 dev ens192 proto static metric 100
    10.10.13.0/24 dev ens192 proto kernel scope link src 10.10.13.63 metric 100
    10.244.0.0/24 via 10.244.0.0 dev flannel.1 onlink
    10.244.2.0/24 dev cni0 proto kernel scope link src 10.244.2.1
    10.244.4.0/24 via 10.244.4.0 dev flannel.1 onlink
    172.17.70.0/24 dev docker0 proto kernel scope link src 172.17.70.1
    ```

    从上面的命令可见，如果是发往目标 ip 是在本机网段`10.244.2.0/24`内的，数据包仍然走 cni0；如果是其他网段 `10.244.0.0/24`/`10.244.4.0/24`，则走 flannel.1

    这里应该通过 flannel.1 发往 10.244.4.0。

4. 通过 arp 缓存找到 10.244.4.0 对应的 flannel.1 的 mac 地址 86:fa:ee:23:17:92。对于这个 ip 报文，会再封装成 mac 帧，源 mac 地址是本机 flannel.1 的 mac 地址，目的 mac 地址是对端 flannel.1 的 mac 地址。

    ```
    [root@node02 ~]# arp
    Address                  HWtype  HWaddress           Flags Mask            Iface
    ...
    10.244.4.0               ether   86:fa:ee:23:17:92   CM                    flannel.1
    10.244.0.0               ether   9e:14:c6:42:2e:bf   CM                    flannel.1
    ...
    ```

5. 在  flannel.1 的 fdb 中，通过 mac 地址 86:fa:ee:23:17:92 找到这个包改发往哪个（二层）接口，这里的接口是 node 上的外部网卡 ens192 的 ip 10.10.13.62。

    原始 IP 分组（`10.244.2.48 -> 10.244.4.2`）所在的 MAC 帧（本机 VTEP MAC -> 对端 VTEP MAC），会被 VTEP 封装成 UDP 数据报（源 IP 地址是发送端主机外部网卡的 IP 10.10.13.63，目的 IP 地址是接收端主机外部网卡的 IP 10.10.13.62，目的端口是 VxLAN 的监听端口 4789）。

    封装的时候会在 UDP 中加入 VxLAN 的控制信息，比如 VNI。这里 VNI 是 1. flannel.1 命名中的 1 就指示了 VNI 号。同一个 VNI 号的属于同一个网络。

    ```
    [root@node02 ~]# bridge fdb show dev flannel.1
    86:fa:ee:23:17:92 dev flannel.1 dst 10.10.13.62 self permanent
    9e:14:c6:42:2e:bf dev flannel.1 dst 10.10.13.61 self permanent
    ```

6. 封装完毕后会从外部网卡发送出去。将 MAC 帧从 UDP 数据报中拆出来，并检查 VNI 号。如果是同一个 VNI 的，往协议层上层走。

    这个帧中的 IP 分组，目的 IP 就是 10.244.4.2，查找路由表，是发往 cni0 的。 cni0 会将这个 IP 分组转发到对应的接口，也就是 10.244.4.2 所在的 pod 网卡。


# 3.总结

本文重点在于 flannel 的实现，以及 k8s 网络的组成，限于篇幅，忽略了一些细节和相关知识的介绍，但要深入理解 k8s pod 网络，仍然有不少相关的知识点值得探讨，例如：

1. VxLAN 协议的具体实现
2. CNI 插件的实现
3. 内核抽象网络设备的实现
4. 其他网络的实现，如使用 BGP 而非 overlay 的calico方案

flannel 相对而言还是比较简单的，它实现了跨主机的集群网络，但没有提供更多的功能，比如访问控制。 

flannel 有大量操作 Linux 网络设备的代码，如创建 VxLAN 设备、操作路由、操作 fdb 等，使用了`github.com/vishvananda/netlink`这个库来做相关的调用。

flannel 除了使用 VxLAN 作为后端，还可以用 ipsec、ipip、gce、udp 封装等方式，但都大同小异，他们都实现了`backend/common.go`中的 interface。

```
type Backend interface {
	// Called when the backend should create or begin managing a new network
	RegisterNetwork(ctx context.Context, wg *sync.WaitGroup, config *subnet.Config) (Network, error)
}
```

# 4.Ref

[flannel github repo](https://github.com/coreos/flannel)

[flannel 网络架构
](https://ggaaooppeenngg.github.io/zh-CN/2017/09/21/flannel-%E7%BD%91%E7%BB%9C%E6%9E%B6%E6%9E%84/)

[CNI - Container Network Interface（容器网络接口）](https://jimmysong.io/posts/kubernetes-open-interfaces-cri-cni-csi/#cni-container-network-interface-%E5%AE%B9%E5%99%A8%E7%BD%91%E7%BB%9C%E6%8E%A5%E5%8F%A3)

[CNI plugins github repo](https://github.com/containernetworking/plugins)
