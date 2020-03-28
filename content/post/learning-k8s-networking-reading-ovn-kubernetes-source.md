---
title: "Kubernetes 网络学习：阅读 ovn-kubernetes 源码"
date: 2019-12-29T22:37:00+08:00
draft: false
categories: [技术文章]
---

# 1. 软件定义网络介绍
---

何谓软件定义网络（SDN，software-defined networking）

根据维基百科的定义：软件定义网络是一种新型网络架构。它利用OpenFlow协议将路由器的控制平面（control plane）从数据平面（data plane）中分离，改以软件方式实现。该架构可使网络管理员在不更动硬件设备的前提下，以中央控制方式用程序重新规划网络，为控制网络流量提供了新方案，也为核心网络和应用创新提供了良好平台。

在传统网络中，我们要修改整个网络的配置，可能需要去每一台路由器上面更改路由配置；而在 SDN 中，只需要修改 SDN 的集中控制器，配置的更改会被控制器通过统一的协议下发到路由器上。这里路由器是实际数据转发的节点，但路由信息的配置转移到了集中控制器上，使得更改网络配置更加灵活。

# 2. OVN (Open Virtual Network)介绍
---

Open vSwitch（OVS）是一款开源的分布式虚拟交换机，可以理解成软件实现的交换机。而 OVN 是基于 OVS 实现的一套网络方案，可以虚拟出二层和三层的网络。

[OVN 的架构图](http://www.openvswitch.org/support/dist-docs/ovn-architecture.7.html)如下：

```
                                         CMS
                                          |
                                          |
                              +-----------|-----------+
                              |           |           |
                              |     OVN/CMS Plugin    |
                              |           |           |
                              |           |           |
                              |   OVN Northbound DB   |
                              |           |           |
                              |           |           |
                              |       ovn-northd      |
                              |           |           |
                              +-----------|-----------+
                                          |
                                          |
                                +-------------------+
                                | OVN Southbound DB |
                                +-------------------+
                                          |
                                          |
                       +------------------+------------------+
                       |                  |                  |
         HV 1          |                  |    HV n          |
       +---------------|---------------+  .  +---------------|---------------+
       |               |               |  .  |               |               |
       |        ovn-controller         |  .  |        ovn-controller         |
       |         |          |          |  .  |         |          |          |
       |         |          |          |     |         |          |          |
       |  ovs-vswitchd   ovsdb-server  |     |  ovs-vswitchd   ovsdb-server  |
       |                               |     |                               |
       +-------------------------------+     +-------------------------------+
```

OVN Northbound DB / ovn-northd / OVN Southbound DB 部署在 Central 节点（master）上；ovn-controller / ovs-vswitch / ovsdb-server 部署在 Chassis 节点（slave）上。

OVN 网络设置的大致流程：OVN/CMS Plugin 或用户使用 ovn-nbctl 更改 OVN Northbound DB 里的数据，定义 logical router / logical switch 等虚拟网络组件，ovn-northd 从 OVN Northbound DB 读取数据，翻译成 logical flow 写到 OVN Southbound DB；每台 chassis 上的 ovn-controller 读取 OVN Southbound DB 里的 logical flow 翻译成 openflow 配置写到 ovsdb-server 里，ovs-vswitchd 执行 openflow 规则。

# 3. ovn-kubernetes介绍
---

ovn-kubernetes 是一个将 OVN 网络方案引入到 k8s 体系兼容 CNI 标准的一套代码，将 pod、service 网络都用 OVN 网络来实现。

ovn-kubernetes 组件（1，2，3）是以 k8s 对象的形式在 k8s 集群内部署：

1. ovnkube-db deployment(包含 nb-ovsdb,sb-ovsdb 两个容器)：顾名思义，部署的是ovn 的两个 db
2. ovnkube-master deployment(包含 ovn-northd,nbctl-daemon,ovnkube-master 三个容器)：用来初始化 master 节点，并监听集群中对象的变化对 ovn 网络进行相应的配置；运行一个 cni 二进制的 http 服务器，相应 cmdAdd 和 cmdDel
3. ovnkube daemonset for nodes(ovs-daemons,ovn-controller,ovnkube-node)：每台 node 上的守护进程，初始化 node
4. ovn-k8s-overlay：CNI plugin 二进制，当 pod 创建/销毁的时候，会被 kubelet 调用

ovn-kubernetes 生成的逻辑上的网络架构：

```
                                +----------------------+
                                |                      |
                                |   OvnClusterRouter   |
                 +--------------+                      +--------------------------------+
                 |              |   (logical router)   |                                |
                 |              |                      |                                |
                 |              +--------------+-------+                                |
                 |                             |                                        |
                 |                             |                              +---------+---------+
     +-----------+---------+            +------+--------------+               |                   |
     |                     |            |                     |               |   join            |
     |   [nodename1]       |            |   [nodename2]       |               |                   |
     |                     |            |                     |               |   (logical switch)|
     |   (logical switch)  |            |   (logical switch)  |               |                   |
     |                     |            |                     |               +--+------+------+--+
     +-+---------+--------++            +-+---------+--------++                  |      |      |
       |         |        |               |         |        |                   |      |      +
       |         |        +               |         |        +                   |      |     ...
       |         |       ...              |         |       ...                  |      |
       |         |                        |         |           +----------------+-+  +-+----------------+
+------++     +--+---+             +------+      +--+---+       |                  |  |                  |
|       |     |      |             |      |      |      |       |  GW-[nodename1]  |  |  GW-[nodename2]  |
| Pod1  |     | Pod2 |             | Pod3 |      | Pod4 |       |                  |  |                  |
|       |     |      |             |      |      |      |       | (gateway router) |  | (gateway router) |
+-------+     +------+             +------+      +------+       |                  |  |                  |
                                                                +----------+-------+  +---------+--------+
                                                                           |                    |
                                                                           |                    |
                                                                 +---------+-------+     +------+----------+
                                                                 |                 |     |                 |
                                                                 | ext-[nodename1] |     | ext-[nodename2] |
                                                                 |                 |     |                 |
                                                                 | (local network) |     | (local network) |
                                                                 |                 |     |                 |
                                                                 +-----------------+     +-----------------+



```

以上 logical router / logical switch 都是逻辑/虚拟的，每添加一台新的 node，ovn-kubernetes 会新建一台用 nodename 命名的 logical switch 连接到全局唯一的 OvnClusterRouter 上，每当有新的 pod 调度到 node，pod 就连接到对应 node 的 logical switch 上，用来形成 pod 网络（overlay / 东西向流量）。添加新 node 的同时，ovn-kubernetes 还会建立一个绑定到每一台 node 的 gateway router，连接到 join（join 是与 OvnClusterRouter 相连的 logical switch），用来连接 pod 网络（overlay）和 node 网络（underlay）（南北向流量）

# 4. ovn-kubernetes 源码阅读笔记
---

ovnkube-master 和 ovnkube-node 实际上都是同一个可执行文件 ovnkube，只不过参数不通

## ovnkube 的代码逻辑

1. CleanupClusterNode
2. 启动 master 或 node 逻辑

下面分别从 node 和 master 来介绍源码

## node 启动逻辑

```go
err = setupOVNNode(name)
```


1. 初始化 ovs-vsctl

	调用 ovs-vsctl 设置封装协议、本机 IP、本机主机名等
	
		util.RunOVSVsctl("set",
				"Open_vSwitch",
				".",
				fmt.Sprintf("external_ids:ovn-encap-type=%s", config.Default.EncapType),
				fmt.Sprintf("external_ids:ovn-encap-ip=%s", nodeIP),
				fmt.Sprintf("external_ids:ovn-remote-probe-interval=%d",
					config.Default.InactivityProbe),
				fmt.Sprintf("external_ids:hostname=\"%s\"", nodeName),
			)

2. 等待 master 节点创建该 node 的 logical_switch

		 		if cidr, _, err = util.RunOVNNbctl("get", "logical_switch", node.Name, "other-config:subnet"); err != nil {
					logrus.Errorf("error retrieving logical switch: %v", err)
					return false, nil
				}

3. 初始化 Gateway
4. 创建 ManagementPort，用来让 node 通过私有 IP 访问 pods（做 health checking 等管理工作）

	`func CreateManagementPort(nodeName string, localSubnet *net.IPNet, clusterSubnet []string) (map[string]string, error)` 的逻辑:

	1. 创建 ovs bridge： br-int
 	2. 在 br-int 上创建 internal port / interface： k8s-[nodeName]
 	
		  	stdout, stderr, err = util.RunOVSVsctl("--", "--may-exist", "add-port",
				"br-int", interfaceName, "--", "set", "interface", interfaceName,
				"type=internal", "mtu_request="+fmt.Sprintf("%d", config.Default.MTU),
				"external-ids:iface-id=k8s-"+nodeName)

	3. 给 internal interface 设置 IP（本地子网的第一个IP），添加 pod cidr 和 svc cidr 的路由到 stor-[nodeName]（ip为本地子网的下一个IP）
   4. 在 k8s-[nodeName] 上添加 arp 记录，将 stor-[nodeName] 的 routeIP 和 routeMac 关联起来
   5. 设置必要的 iptables 规则：把从 internal interface 出去的包 SNAT 成该网卡的 IP
   6. 将 internal interface 的 mac 地址写到 annotations 里（"k8s.ovn.org/node-mgmt-port-mac-address"）并返回

5. 设置 node annotations
6. 写 CNI 配置，启动 CNI server

下面细致讲一下以上第3步（初始化 Gateway）和第6步（启动 CNI server）的流程：


### 初始化 Gateway

所谓 Gateway，就是 node 网络进入 ovn 网络的网关

1. 如果开启了 NodePort，则初始化 load_balancer health checker
2. 根据配置里的 Gateway Mode 进行初始化: localnet/shared

localnet 和 shared 模式的区别在于，前者 pod 的流量到达物理网卡需要通过宿主机的 iptables 做 nat 转发，后者是把物理网卡加入到 ovn 的网路中去，不需要通过 iptalbes 规则。

#### 初始化 localneet Gateway

```go
		annotations, err := initLocalnetGateway(nodeName, subnet, cluster.watchFactory)
```

1. 创建 ovs bridge：`br-local`，并启动它
2. 在 br-local 上创建 internal port ：`br-nexthop`，并启动它
3. 将 localnetGatewayNextHopSubnet("169.254.33.1/24") 指定给 br-nexthop
4. 给 br-local 设置 mac 地址，添加到本地网络`physnet`的映射，设置`ifaceID=br-local_[nodeName]`
5. 将 gateway mode、gateway Vlan ID、ifaceID、mac 地址、localnetGatewayIP、localnetGatewayNextHop 等信息写到 annotations 里
6. 设置 NAT 规则
  1. 允许 br-nexthop 收到的包被转发
  2. 追踪来自 br-nexthop 的包
  3. 允许 br-nexthop 进入 localhost
  4. 对来自 localnetGatewayIP（"169.254.33.2/24"）的包进行 SNAT

7. 如果开启了 NodePort，将监听 k8s svc 的事件并设置相应的 NAT 规则


#### 初始化 shared Gateway


```go
// gatewayNextHop / gatewayIntf 若未指定则未默认网卡的下一跳地址/默认网卡名称，假设 gatewayIntf 为 eth0
initSharedGateway(nodeName, subnet, gatewayNextHop, gatewayIntf, cluster.watchFactory)
```

1. 判断该网卡 gatewayIntf 是否为 internal port 或者 OVS bridge，这里考虑该网卡为物理网卡的情况
2. 创建一个 OVS bridge：breth0，并将 eth0 的 IP 和路由设置给 breth0，eth0 被设置为 breth0 的 port

		stdout, stderr, err := RunOVSVsctl(
			"--", "--may-exist", "add-br", bridge,
			"--", "br-set-external-id", bridge, "bridge-id", bridge,
			"--", "br-set-external-id", bridge, "bridge-uplink", iface,
			"--", "set", "bridge", bridge, "fail-mode=standalone",
			fmt.Sprintf("other_config:hwaddr=%s", ifaceLink.Attrs().HardwareAddr),
			"--", "--may-exist", "add-port", bridge, iface,
			"--", "set", "port", iface, "other-config:transient=true")
	
3. 给 breth0 设置 mac 地址，添加到本地网络`physnet`的映射，设置`ifaceID=br-local_[nodeName]` ,设置`ifaceID=br-local_[nodeName]`

		// ovn-bridge-mappings maps a physical network name to a local ovs bridge
		// that provides connectivity to that network.
		_, stderr, err := util.RunOVSVsctl("set", "Open_vSwitch", ".",
	        fmt.Sprintf("external_ids:ovn-bridge-mappings=%s:%s", util.PhysicalNetworkName, bridgeName))
	        
	    ifaceID := bridgeName + "_" + nodeName
 
4. 将 gateway mode、gateway Vlan ID、ifaceID、mac 地址、localnetGatewayIP、localnetGatewayNextHop 等信息写到 annotations 里
5. 设置 openflow 默认 ConntrackRules 规则：规定 pod 与 host 协议栈之间的流量；如果开启了 NodePort，则监听 k8s svc 的事件并设置相应的 openflow 规则

			// Program cluster.GatewayIntf to let non-pod traffic to go to host
			// stack
	        if err := addDefaultConntrackRules(nodeName, bridgeName, uplinkName); err != nil {
				return err
			}
	
			if config.Gateway.NodeportEnable {
				// Program cluster.GatewayIntf to let nodePort traffic to go to pods.
				if err := nodePortWatcher(nodeName, bridgeName, uplinkName, wf); err != nil {
					return err
				}
			}

### 初始化 node 上的 CNI server

主要是两个函数，对应 CNI plugin 的两个命令：

#### cmdAdd()
1. 获取 pod annotations
2. pr.getCNIResult(podInterfaceInfo)-->ConfigureInterface
3. cmdAdd
 1. 创建 veth 对，一端在 ns 里，一端在 host
 2. 根据podInterfaceInfo，设置在 ns 里的虚拟网卡，设置mac地址、ip以及路由
 3. host 端的网络名字设置成容器ID的前16位
 4. ifaceID=[namespace]_[podName]
 5. 查找使用这个 ifaceID 的 ovs port 并移除，添加新的 ovs portL:hostIface.Name
 6. 设置 pod bandwitth


#### cmdDel()
1. 删除 br-int 上的 port
2. 清除 PodBandwidth


## master 启动逻辑

1. 选举
2. 排除掉已经被分配的子网，创建子网分配器
3. 创建逻辑路由器`ovn_cluster_router`
4. 创建tcp和udp的负载均衡器
5. 创建逻辑交换机`join`，分配子网`100.64.0.0/16` 
6. 将 join 连接到 ovn_cluster_router 的 port `rtoj-ovn_cluster_router`
7. 将 ovn_cluster_router 连接到 join 的 port `jtor-ovn_cluster_router`

### 启动监听
1. 开一个 goroutine 每隔 30s 更新 nbdb 的时间戳
2. 启动对 node 的监听
3. 启动对 pods / services / endpoints / networkpolicy 的监听

### 对 node 的监听：WatchNodes

	AddFunc: func(obj interface{}) {
				node := obj.(*kapi.Node)
				logrus.Debugf("Added event for Node %q", node.Name)
				hostSubnet, err := oc.addNode(node)
				if err != nil {
					logrus.Errorf("error creating subnet for node %s: %v", node.Name, err)
					return
				}
	
				err = oc.syncNodeManagementPort(node, hostSubnet)
				if err != nil {
					logrus.Errorf("error creating Node Management Port for node %s: %v", node.Name, err)
				}
	
				if err := oc.syncNodeGateway(node, hostSubnet); err != nil {
					gatewaysFailed[node.Name] = true
					logrus.Errorf(err.Error())
				}
			},
	
下面具体讲一下这三个函数具体做了什么：

#### 1. `func (oc *Controller) addNode(node *kapi.Node) (hostsubnet *net.IPNet, err error)` 

1. 从 node 的 annotations 中获取 hostnet
2. 如果 hostnet 已经存在，确保逻辑网络已经被设置
 1. 获取 hostsubnet 的第一个和第二个 IP（第二个为 node 上 management port 的 IP）
 2. 获取 logical_router_port：`rtos-[nodeName]`的 mac 地址，如果为空则生成一个
 3. 在 ovn_cluster_router 上添加 port：`rtos-[nodeName]`，同时 IP 为上述第一个 IP，mac 地址为上述 mac
 4. 添加逻辑交换机`[nodeName]`，设置已存在的 hostnet，设置 gateway_ip 为第一个 IP
 5. 在`[nodeName]`上添加 port `str-[nodeName]` 连接到`rtos-[nodeName]`
 6. 在 `[nodeName]` 上添加负载均衡器
3. 如果 hostnet 未存在，使用子网分配器获取子网
4. 确保逻辑网络建立
5. 设置 node 的 annotations
6. 返回 hostnet

#### 2. `func (oc *Controller) syncNodeManagementPort(node *kapi.Node, subnet *net.IPNet) error` 

1. 获取 management port 的 mac 地址
2. 如果 mac 为空，则删除 k8s-[nodeName]
3. 在逻辑交换机 `[nodeName]`上添加 logical port `k8s-[nodeName]`

```go
	// Create this node's management logical port on the node switch
	stdout, stderr, err := util.RunOVNNbctl(
		"--", "--may-exist", "lsp-add", node.Name, "k8s-"+node.Name,
		"--", "lsp-set-addresses", "k8s-"+node.Name, macAddress+" "+portIP.IP.String(),
		"--", "--if-exists", "remove", "logical_switch", node.Name, "other-config", "exclude_ips")
```

#### 3. `func (oc *Controller) syncNodeGateway(node *kapi.Node, subnet *net.IPNet) error`

如果 gatewaymode 为空，清理；

如果为非空，则同步网关逻辑网络

1. 从配置获取集群的子网
2. 从 node 的 annotations 中获取 ifaceID、gateway mac 地址、gateway IP 地址、默认网关 IP 地址、VLAN ID
3. 创建 geteway router: `GR_[nodeName]`

		// Create a gateway router.
		gatewayRouter := "GR_" + nodeName
		stdout, stderr, err := RunOVNNbctl("--", "--may-exist", "lr-add",
			gatewayRouter, "--", "set", "logical_router", gatewayRouter,
			"options:chassis="+systemID, "external_ids:physical_ip="+physicalIP)
	 
4. 在 join 上创建 lsp：`jtor-GR_[nodeName]`，并分配 mac 地址routerMac和 IP 地址routerCIDR
5. 在 gatewayRouter 上创建 lrp：`rtoj-GR_[nodeName]`，mac和IP设置为`jtor-GR_[nodeName]`的
6. 在 gatewayRouter设置options：lb_force_snat_ip：`rtoj-GR_[nodeName]`的IP
7. 在 gatewayRouter添加到达每个子网的路由，`via 100.64.0.1`
8. 在 `ovn_cluster_router`上添加到gatewayRouter的默认路由
9. 在gatewayRouter上添加负载均衡器
10. 创建逻辑交换机 `ext_[nodeName]`，添加 port：[ifaceID]，并设置为 localnet，将交换机连接到`GR_[nodeName]`
11. 在gatewayRouter上添加静态路由 `0.0.0.0/0 默认网关IP地址 rtoe-GW_[nodeName]`
12. 在gatewayRouter上添加SNAT规则，将去子网的包 snat 成 gateway IP
13. 在`ovn_cluster_router`上添加/32 路由：routerCIDR routerCIDR



### 对 pod 的监听： WatchPods

	func (oc *Controller) addLogicalPort(pod *kapi.Pod) error

1. 等待和node同名的logical switch建立
2. 读取pod的annotations，在logical switch上建立port：[pod.Namespace + "_" + pod.Name]，如果annotations中的ip和mac已经存在，则直接设置到port，如果不存在则设置成dynamic的
3. 获取logical switch 上的gateway ip
4. 在annotaions里写IP、MAC、GW
5. 把pod加到ns里
6. 设置pod的annotaions

### 对  services / endpoints / networkpolicy 的监听

这几个监听是 service 网络的建立以及访问控制的实现，套路实际上都差不多，相应从 k8s-apiserver 监听到的事件，然后调用 ovn/ovs 写入 openflow 流表，使得整个逻辑网络实现我们想要的行为。

# 5. REF
---

1. http://www.openvswitch.org/support/dist-docs/ovn-architecture.7.html 
2. https://github.com/ovn-org/ovn-kubernetes
3. http://blog.spinhirne.com/2016/09/a-primer-on-ovn.html OVN 入门系列文章，可以参考这个系列实践一下 OVN 相关的操作，如创建虚拟交换机、虚拟路由器、负载均衡、网关、实现容器网络等
3. https://en.wikipedia.org/wiki/Open_vSwitch
4. https://en.wikipedia.org/wiki/Software-defined_networking
5. https://en.wikipedia.org/wiki/OVN
