---
title: "容器运行时笔记"
date: 2019-08-01T08:14:03+08:00
draft: false
---

Kubernetes 通过容器运行时（container runtime）来启动和管理容器。[官方文档](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)列举了以下几种 runtime：Docker，CRI-O，Containerd，fraki。它们之间有什么区别和联系呢？经常会看到 OCI、CRI 这些缩写，这些和容器、docker 到底是什么关系呢？

这篇文章不会深入到很细节的部分，旨在为初学者提供一个比较初步的概览，对一些基本概念做一些简单介绍。

简单说说什么是容器。容器实际上是 Linux 内核几组功能的组合：cgroup、namespace 和 union file system。cgroup 用来限制进程组所使用的系统资源（CPU、Memory、IO 等）；namespace 用来隔离进程对系统资源的访问（IPC、Network、PID 等），让不同 namespace 的进程看不到彼此的存在；union file system 用来支持对文件系统的修改分层。

容器并不是虚拟机。虚拟机一般会虚拟完整的操作系统内核，而容器只是虚拟进程的运行环境。容器用到的技术，本身就是内核提供的。容器与容器是共享一个内核的，而虚拟机与虚拟机有可能跑在同一台物理机器上但是各有一个内核。

容器运行时是管理容器和容器镜像的程序。对于 k8s 而言，runtime 指的是 CRI-runtime，它不关心如何调用内核 API，只规定了 kubelet 与容器相关的接口；对于 docker 而言，runtime 一般指的是 ORI-runtime，封装具体的内核交互和系统调用。

# OCI 标准

OCI（Open Container Initiative）标准是由 Docker 公司主导的一个关于容器格式和运行时的标准或规范，包含运行时标准（[runtime-spec](https://github.com/opencontainers/runtime-spec/blob/master/spec.md)
）和容器镜像标准（[image-spec](https://github.com/opencontainers/image-spec/blob/master/spec.md)）。运行时标准规定了怎么去运行一个容器，如何去表达容器的状态（state）和生命周期（lifestyle）、如何设置 namespace、cgroup、文件系统等等，可以理解为运行期的动态描述；而容器镜像标准规定了容器镜像的格式、配置、元数据等，可以理解为对镜像的静态描述。

为什么要搞这么一个标准呢？应该是为了防止各家容器各有一套互不兼容的格式导致生态过于碎片化，另外一个目的是尽管目前只有 Linux 系统有容器，但万一我们要在 Windows 或者 Unix 上实现容器，要不要重新搞一套标准呢？OCI 规范也可以在其他操作系统和平台上实现。

## runc

OCI 规范在 Linux 上的完整实现是 runC。我们通过 runC 命令可以看到一些基本的说明：

```
[root@master ~]# runc --help
NAME:
   runc - Open Container Initiative runtime

runc is a command line client for running applications packaged according to
the Open Container Initiative (OCI) format and is a compliant implementation of the
Open Container Initiative specification.

......
```

从 runc 的 help 输出可以看到，这是一个符合 OCI 规范的命令行工具。我们可以通过  `runc run [ -b bundle ] <container-id>` 来启动一个容器。`bundle` 是一个包含描述文件 `config.json` 和 rootfs 的路径。

## runsc in gViser

google 出品的 [gViser](https://github.com/google/gvisor) 实现了一个用户空间的 kernel，也就说，在用户空间模拟了系统调用(syscall)。它是通过[沙盒(Sandbox)]( https://en.wikipedia.org/wiki/Sandbox_(computer_security) )的机制来为进程提供更强的隔离性，容器将跑在用户空间的沙盒里，而不是内核空间了。它包含了一个符合 OCI 标准的 runtime——`runsc`。兼容 OCI 标准使得它容易与 docker 和 k8s 集成。

# CRI 标准

Docker 应该是最出名的容器引擎或容器运行时了。k8s 早期只支持 docker ，后来为了让 k8s 和 docker 解耦，防止绑定在特定的运行时上面，k8s 开放了容器运行时接口（CRI）。该接口是基于 gRPC 的，容器运行时只要实现了 CRI，就能和 k8s 集成。

除了 CRI，k8s 还开放了容器网络接口（CNI，Container Network Interface）和容器存储接口（CSI，Container Storage Interface）。用户或者管理员可以根据自己的实际需求使用不同的容器运行时、网络插件和存储驱动，只要他们实现了相应的接口，而不需要对 k8s 源码做特殊的改动。

除了 Docker，还有 CRI-O、Containerd。

可以通过修改 kubelet 的参数来配置不同的 CRI 运行时。kubelet 运行在每一个 node 上面，k8s 通过 kubelet 来启动容器。

通过 `kubelet --help` 查看相关参数的说明：

```
      --container-runtime string                                                                                  The container runtime to use. Possible values: 'docker', 'remote', 'rkt (deprecated)'. (default "docker")
      --container-runtime-endpoint string                                                                         [Experimental] The endpoint of remote runtime service. Currently unix socket endpoint is supported on Linux, while npipe and tcp endpoints are supported on windows.  Examples:'unix:///var/run/dockershim.sock', 'npipe:////./pipe/dockershim' (default "unix:///var/run/dockershim.sock")
```

默认情况下，kubelet 是通过内置的 docker-shim 调用 docker 来创建容器。 `--container-runtime=remote` 指定了其他的运行时，` --container-runtime-endpoint` 指定了该运行时的访问端点。

比如我想使用 CRI-O 作为 k8s 的容器进行时，我可以这么设置：

```
--container-runtime=remote --container-runtime-endpoint=/var/run/crio/crio.sock --cgroup-driver=systemd
``` 

同时启动 crio 的 daemon：`systemctl start crio` 并重启 kubelet：`systemctl restart kubelet`

通过 CRI 的命令行客户端 `crictl` 可以查看版本：


```
[root@master ~]# crictl version
Version:  0.1.0
RuntimeName:  cri-o
RuntimeVersion:  1.11.11-1.rhaos3.11.git474f73d.el7
RuntimeApiVersion:  v1alpha1
```

可以看到 RuntimeName 是 cri-o。

假如 kubelet 配置的是 docker，`crictl version` 的结果是：

```
[root@node01 ~]# crictl version
Version:  0.1.0
RuntimeName:  docker
RuntimeVersion:  18.09.6
RuntimeApiVersion:  1.39.0
```

## docker

现在安装比较新的 docker（18.09.6），会看到实际上至少会有三个组件：runC、containerd、dockerd。

dockerd 是个守护进程，直接面向用户，用户使用的命令 docker 直接调用的后端就是 dockerd；dockerd 不会直接使用 runc，而是去调用 containerd；containerd 会 fork 出一个单独子进程的 containerd-shim，使用 runc 将目标容器跑起来。

Kubelet 则是通过内置的 docker-shim 去调用 dockerd。



```
+--------------------+
|                    |
|                    |  CRI gRPC
|   kubelet          +-----+                                                  +---------------+     +--------------+
|                    |     |                                                  |               |     |              |
|                    |     |   +---------------+       +--------------+ fork  |container-shim +----->  container   |
|      +-------------+     |   |               |       |              +------->               |     |              |
|      |             |     |   |               |       |              |       +---------------+     +--------------+
|      |            A+<----+   |               |       |              |                      runc(OCI)
|      | dockershim  |         |    dockerd    |       |  containerd  |       +---------------+     +--------------+
|      |             +--------->B              +------->C             |       |               |     |              |
|      |             |         |               |       |              +------->container-shim +----->  container   |
|      |             |         |               |       |              |       |               |     |              |
+------+-------------+         +---------------+       +--------------+       +---------------+     +--------------+
                                                                      |
                    A:unix:///var/run/dockershim.sock                 +------> ......

                                                        C:/run/containerd/containerd.sock
                                B:/var/run/docker.sock

```


通过 `ps -ef ` 可以看到几个进程之间的关系：

```
root      5904     1  0 Jul28 ?        00:21:59 /usr/bin/containerd
root      7824  5904  0 Jul28 ?        00:00:04 containerd-shim -namespace moby -workdir /var/lib/containerd/io.containerd.runtime.v1.linux/moby/cf8911b66df50d267e7bd6699dc38c2c4e5b7324ce9c9bf2108800b957035813 -address /run/containerd/containerd.sock -containerd-binary /usr/bin/containerd -runtime-root /var/run/docker/runtime-runc
root      7892  7824  0 Jul28 ?        00:00:46 /frpc -c /conf/frpc.ini
```

看起来 kubelet 与 docker 之间的交互还是蛮复杂的，其中有很多历史原因，也牵扯到 k8s 与 docker（Swarm） 之间的竞争。但 docker 在容器领域是还是最出名的，用 docker 的人是最多的。kubelet 默认也是使用 docker 作为容器运行时。所以如果遇到问题比较容易找到相关的资料。

## CRI-O

CRI-O 是 RedHat 发布的容器运行时，旨在同时满足 CRI 标准和 OCI 标准。kubelet 通过 CRI 与 CRI-O 交互，CRI-O 通过 OCI 与 runC 交互，追求简单明了。可以看到，在这种方式下，就不需要使用 docker 了。

```
                                          +----------+          +--------------+
                                          |          |          |              |
                                          |  conmon  +---------->  container   |
+-------------+       +--------------+---->          |          |              |
|             |       |              |    +----------+          +--------------+
|             |       |              |                 runc(OCI)
|   kubelet   | CRI   |    CRI-O     |    +----------+          +--------------+
|             +------->A             |    |          |          |              |
|             |       |              +---->  conmon  +---------->  container   |
|             |       |              |    |          |          |              |
+-------------+       +--------------+    +----------+          +--------------+
                                     |
                                     +---->......

                       A:/var/run/crio/crio.sock

```

## cri-containerd

Containerd 也是 docker 公司实现的，后来捐献给了 CNCF。contianerd 把 dockerd 与 runc 解耦了，dockerd 不直接创建容器，而是通过 containerd 去调用 runc。从 contianerd 1.1 开始，contianerd 可以以插件的方式集成 CRI。contianerd 也可以使用除 runc 以外的容器引擎。

```
+--------------------+         +----------------------+          +---------------+     +--------------+
|                    |         |                      |          |               |     |              |
|                    |         |                      |  fork    |container-shim +----->  container   |
|   kubelet          |         |  containerd          +---------->               |     |              |
|                    |         |                      |          +---------------+     +--------------+
|                    |         |                      |                         runc(OCI)
|                    |         +--------------+       |          +---------------+     +--------------+
|                    |         |              |       |          |               |     |              |
|                    |         |  CRI-plugin  |       +---------->container-shim +----->  container   |
|                    |         |              |       |          |               |     |              |
|                    +--------->A             |       |          +---------------+     +--------------+
|                    |         |              |       |
|                    |         |              |       +---------->......
+--------------------+         +--------------+-------+

                                A:/run/containerd/containerd.sock
```

使用 containerd 的优势是可配置性，可以通过插件的方式更换具体的实现。

## 强隔离 runtime：Frakti、gVisor...

容器毕竟还是共享内核的，安全性和隔离型对于想要实现多租户是不够。所以又出现了许多基于虚拟机隔离的方案出来。

Frakti 提供了hypervisor级别的隔离性，官网的原话是：

> Frakti lefts Kubernetes run pods and containers directly inside hypervisors via runV. It is light weighted and portable, but can provide much stronger isolation with independent kernel than linux-namespace-based container runtimes.

提供的是内核级别的而非Linux命名空间级别的隔离。

gVisor 我的理解是拦截了系统调用，用自己实现用户态的进程而非内核来处理系统调用。

# 使用相关的命令行工具来查看容器信息

为了更加清晰地理清各种乱七八糟的 daemon，我们可以在一个运行的 k8s 集群里，通过命令行客户端来看一下实际运行的容器是怎样的。

## 环境

按照默认方式安装了 1 master 2 nodes 的 k8s 集群，三台机器都是 centos 7。IP 如下：

```
Master 10.10.13.61
Node1 10.10.13.62
Node2 10.10.13.63
```

k8s 版本：

```
[root@master runc]# kubectl version
Client Version: version.Info{Major:"1", Minor:"14", GitVersion:"v1.14.3", GitCommit:"5e53fd6bc17c0dec8434817e69b04a25d8ae0ff0", GitTreeState:"clean", BuildDate:"2019-06-06T01:44:30Z", GoVersion:"go1.12.5", Compiler:"gc", Platform:"linux/amd64"}
Server Version: version.Info{Major:"1", Minor:"14", GitVersion:"v1.14.3", GitCommit:"5e53fd6bc17c0dec8434817e69b04a25d8ae0ff0", GitTreeState:"clean", BuildDate:"2019-06-06T01:36:19Z", GoVersion:"go1.12.5", Compiler:"gc", Platform:"linux/amd64"}
```

docker 版本：

```
[root@master runc]# docker version
Client:
 Version:           18.09.6
 API version:       1.39
 Go version:        go1.10.8
 Git commit:        481bc77156
 Built:             Sat May  4 02:34:58 2019
 OS/Arch:           linux/amd64
 Experimental:      false

Server: Docker Engine - Community
 Engine:
  Version:          18.09.6
  API version:      1.39 (minimum version 1.12)
  Go version:       go1.10.8
  Git commit:       481bc77
  Built:            Sat May  4 02:02:43 2019
  OS/Arch:          linux/amd64
  Experimental:     false
 ```

为了比较各种运行时的效果，我们设置 master 上的容器运行时为 containerd，node1 为 docker，node2 为 crio。


## master 配置 kubelet 使用 cri-contianerd

生成 containerd 默认配置文件：

```
containerd  config default > /etc/containerd/config.toml
```

可以看到配置文件中 cri 是作为 plugin 存在的：

```
......
[plugins]
  [plugins.cgroups]
    no_prometheus = false
  [plugins.cri]
    stream_server_address = "127.0.0.1"
    stream_server_port = "0"
    enable_selinux = false
    sandbox_image = "registry.cn-hangzhou.aliyuncs.com/google-containers/pause-amd64:3.0"
    stats_collect_period = 10
    systemd_cgroup = false
    enable_tls_streaming = false
    max_container_log_line_size = 16384
    [plugins.cri.containerd]
      snapshotter = "overlayfs"
      no_pivot = false
      [plugins.cri.containerd.default_runtime]
        runtime_type = "io.containerd.runtime.v1.linux"
        runtime_engine = ""
        runtime_root = ""
      [plugins.cri.containerd.untrusted_workload_runtime]
        runtime_type = ""
        runtime_engine = ""
        runtime_root = ""
    [plugins.cri.cni]
      bin_dir = "/opt/cni/bin"
      conf_dir = "/etc/cni/net.d"
      conf_template = ""
    [plugins.cri.registry]
.......
```

配置 kubelet： 在 ExecStart 一行（或修改对应的 EnvironmentFile）添加两个 flag ` --container-runtime=remote --container-runtime-endpoint=/run/containerd/containerd.sock`

```
[Unit]
Description=Kubernetes Kubelet
After=docker.service
Requires=docker.service

[Service]
EnvironmentFile=/k8s/kubernetes/cfg/kubelet
ExecStart=/k8s/kubernetes/bin/kubelet $KUBELET_OPTS --container-runtime=remote --container-runtime-endpoint=/run/containerd/containerd.sock
WorkingDirectory=/var/lib/kubelet
Restart=on-failure
KillMode=process

[Install]
WantedBy=multi-user.target
```

重启 containerd 和 kubelet

```
systemctl restart containerd
systemctl restart kubelet
```

使用 ctr 可以看到有两个 namespace：

```
[root@master ~]# ctr namespace ls
NAME   LABELS
k8s.io
moby
```

一个是 k8s.io， 一个是 moby。这里的 namespace 不是 k8s 层面的，而是 containerd 用来隔离不同的 plugin 的。通过 kubelet 启动的容器，ns 就是 k8s.io，通过 docker 启动的就是 moby。`docker ps `是看不到 k8s.io 下的容器的。对于 containerd 而言， docker 和 kubelet 是两个不同的客户端。

`ctr plugin ls`可以看到启用了哪些插件：

```
[root@master ~]# ctr plugin ls | grep cri
io.containerd.grpc.v1           cri                   linux/amd64    ok
```

使用 crictl 连接 containerd 查看版本信息：

```
[root@master runc]# crictl -r /run/containerd/containerd.sock version
Version:  0.1.0
RuntimeName:  containerd
RuntimeVersion:  1.2.5
RuntimeApiVersion:  v1alpha2
```

Crictl 是 CRI 的客户端，只要通过 `--runtime-endpoint` 参数传递符合 CRI 标准的unix sock，它就可以与 CRI daemon 交互。

安装方法：

```
VERSION="v1.15.0"
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
sudo tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
rm -f crictl-$VERSION-linux-amd64.tar.gz


crictl --help
NAME:
   crictl - client for CRI

USAGE:
   crictl [global options] command [command options] [arguments...]

VERSION:
   v1.15.0

COMMANDS:
.....
```




## 在 node2 上配置 kubelet 使用 cri-o

安装 cri-o：

```
yum install yum-utils
yum-config-manager --add-repo=https://cbs.centos.org/repos/paas7-crio-311-candidate/x86_64/os/
yum install --nogpgcheck cri-o
```

修改 kubelet 启动参数（也可以写在`EnvironmentFile`指定的文件里）：

```
vim /lib/systemd/system/kubelet.service 

[Unit]
......
[Service]
......
ExecStart=/k8s/kubernetes/bin/kubelet $KUBELET_OPTS --container-runtime=remote --container-runtime-endpoint=/var/run/crio/crio.sock --cgroup-driver=systemd
......

[Install]
.......

``` 

启动 crio：

```
systemctl start crio
```

使用 crictl 查看版本：

```
[root@node02 ~]# crictl version 
Version:  0.1.0
RuntimeName:  cri-o
RuntimeVersion:  1.11.11-1.rhaos3.11.git474f73d.el7
RuntimeApiVersion:  v1alpha1
```

重启 kubelet

```
systemctl restart kubelet
```


## 观察容器情况

快速创建一个 pod，k8s 会根据各节点的负载情况进行调度：

```
kubectl create -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: busybox1
  namespace: default
spec:
  containers:
  - image: busybox
    command:
      - sleep
      - "3600"
    imagePullPolicy: IfNotPresent
    name: busybox
  restartPolicy: Always
EOF
```

pod 是 k8s 的概念，可以理解成容器组。一个 pod 里一般会有一个 pause 容器和其他一个或多个容器。


### 在 master 上  


```
[root@master yaml]# kubectl get po --all-namespaces -o wide | grep 13.61
default       busybox1                                  1/1     Running   0          18m    10.88.42.142   10.10.13.61   <none>           <none>
kube-system   traefik-ingress-lb-cmkx9                  1/1     Running   5          7d5h   10.10.13.61    10.10.13.61   <none>           <none>
```

busybox1 被调度到了 master 上，此时 master 上有两个 pod。


```
[root@master yaml]# docker ps
CONTAINER ID        IMAGE                         COMMAND                  CREATED             STATUS              PORTS                                           NAMES
3cc0ec11447c        tomcat                        "catalina.sh run"        3 weeks ago         Up 45 hours         0.0.0.0:8088->8080/tcp                          pilot_compose_tomcat_1
cf8911b66df5        registry.local/frp:20190613   "/frpc -c /conf/frpc…"   6 weeks ago         Up 45 hours         80/tcp, 443/tcp, 6000/tcp, 7000/tcp, 7500/tcp   frpc
```

通过 docker 的命令可以看到有两个容器，但不是 k8s 启动的 busybox1 或者 traefik-ingress。

`ps` 一下：

```
[root@master yaml]# ps -ef | grep containerd
root      5904     1  0 Jul28 ?        00:23:38 /usr/bin/containerd
root      7824  5904  0 Jul28 ?        00:00:05 containerd-shim -namespace moby -workdir /var/lib/containerd/io.containerd.runtime.v1.linux/moby/cf8911b66df50d267e7bd6699dc38c2c4e5b7324ce9c9bf2108800b957035813 -address /run/containerd/containerd.sock -containerd-binary /usr/bin/containerd -runtime-root /var/run/docker/runtime-runc
root      7833  5904  0 Jul28 ?        00:00:05 containerd-shim -namespace moby -workdir /var/lib/containerd/io.containerd.runtime.v1.linux/moby/3cc0ec11447cbe50dde34474e1936fb940a2c7ebb49cd6099cf70f742992f60b -address /run/containerd/containerd.sock -containerd-binary /usr/bin/containerd -runtime-root /var/run/docker/runtime-runc
root      9574  5904  0 Jul28 ?        00:00:04 containerd-shim -namespace k8s.io -workdir /var/lib/containerd/io.containerd.runtime.v1.linux/k8s.io/81cdaebde5e69ea08c14e2567b69fb76dcde38023eac7bf24a6993a99b2485ac -address /run/containerd/containerd.sock -containerd-binary /usr/bin/containerd -runtime-root /run/runc
root     14382  5904  0 Jul28 ?        00:00:06 containerd-shim -namespace k8s.io -workdir /var/lib/containerd/io.containerd.runtime.v1.linux/k8s.io/1fc14cf22c0fc99ccf9c1e08709a96dacbce70d2e548712e15c22bd07e64270f -address /run/containerd/containerd.sock -containerd-binary /usr/bin/containerd -runtime-root /run/runc
root     15449  5904  0 15:38 ?        00:00:00 containerd-shim -namespace k8s.io -workdir /var/lib/containerd/io.containerd.runtime.v1.linux/k8s.io/fcf197c1366c21624a0cefe8d0975066956dfae6b1bb0bddbdbaa018354fdca4 -address /run/containerd/containerd.sock -containerd-binary /usr/bin/containerd -runtime-root /run/runc
root     15628  5904  0 15:38 ?        00:00:00 containerd-shim -namespace k8s.io -workdir /var/lib/containerd/io.containerd.runtime.v1.linux/k8s.io/ccc4612d874ef21c9bd36976cd815280e837830c3e01170c6c13f6b0687d3d64 -address /run/containerd/containerd.sock -containerd-binary /usr/bin/containerd -runtime-root /run/runc
```

一共有6个containerd-shim进程，都是containerd的子进程。2个namespace为moby，是docker启动的，4个是k8s.io，由kubelet启动。因为 k8s 每个 pod 都有一个 pause 容器，所以和我们之前看到的两个pod是能对应上的。

```
[root@master yaml]# ps -ef | grep 15628
root     15628  5904  0 15:38 ?        00:00:00 containerd-shim -namespace k8s.io -workdir /var/lib/containerd/io.containerd.runtime.v1.linux/k8s.io/ccc4612d874ef21c9bd36976cd815280e837830c3e01170c6c13f6b0687d3d64 -address /run/containerd/containerd.sock -containerd-binary /usr/bin/containerd -runtime-root /run/runc
root     15655 15628  0 15:38 ?        00:00:00 sleep 3600
```

15655 这个进程就是我们刚刚运行的 busybox1，它是 15628 containerd-shim 的子进程。 



也可以使用 containerd 的 cli 工具： ctr 来观察

```
[root@master yaml]# ctr -n moby t ls
TASK                                                                PID     STATUS
cf8911b66df50d267e7bd6699dc38c2c4e5b7324ce9c9bf2108800b957035813    7892    RUNNING
3cc0ec11447cbe50dde34474e1936fb940a2c7ebb49cd6099cf70f742992f60b    7915    RUNNING


[root@master yaml]# ctr -n k8s.io t ls
TASK                                                                PID      STATUS
81cdaebde5e69ea08c14e2567b69fb76dcde38023eac7bf24a6993a99b2485ac    9602     RUNNING
fcf197c1366c21624a0cefe8d0975066956dfae6b1bb0bddbdbaa018354fdca4    15502    RUNNING
ccc4612d874ef21c9bd36976cd815280e837830c3e01170c6c13f6b0687d3d64    15655    RUNNING
1fc14cf22c0fc99ccf9c1e08709a96dacbce70d2e548712e15c22bd07e64270f    14448    RUNNING
```

15655 只存在 k8s.io ns 下。

使用 crictl 

```
[root@master yaml]# crictl -r /run/containerd/containerd.sock version
Version:  0.1.0
RuntimeName:  containerd
RuntimeVersion:  1.2.5
RuntimeApiVersion:  v1alpha2

[root@master yaml]# crictl -r /run/containerd/containerd.sock ps --all
CONTAINER ID        IMAGE               CREATED             STATE               NAME                 ATTEMPT             POD ID
ccc4612d874ef       db8ee88ad75f6       28 minutes ago      Running             busybox              0                   fcf197c1366c2
1fc14cf22c0fc       18471c10e6e4b       45 hours ago        Running             traefik-ingress-lb   5                   81cdaebde5e69

```

crictl 也是看不到 moby ns 下的容器的。究其原因，是因为 dockerd 与 contianerd 交互未必符合 CRI 标准，kubelet 是在内置的 dockershim 里实现 CRI 。dockershim 通过 restful 接口调用 dockerd。 

因为 containerd 使用 oci-runtime 都是 runc，所以我们可以用runc来查看所有的容器：

```
[root@master runc]# runc -root /run/runc/k8s.io list
ID                                                                 PID         STATUS      BUNDLE                                                                                                                   CREATED                          OWNER
1fc14cf22c0fc99ccf9c1e08709a96dacbce70d2e548712e15c22bd07e64270f   14448       running     /run/containerd/io.containerd.runtime.v1.linux/k8s.io/1fc14cf22c0fc99ccf9c1e08709a96dacbce70d2e548712e15c22bd07e64270f   2019-07-28T11:08:04.234695321Z   root
81cdaebde5e69ea08c14e2567b69fb76dcde38023eac7bf24a6993a99b2485ac   9602        running     /run/containerd/io.containerd.runtime.v1.linux/k8s.io/81cdaebde5e69ea08c14e2567b69fb76dcde38023eac7bf24a6993a99b2485ac   2019-07-28T11:07:55.379537513Z   root
ccc4612d874ef21c9bd36976cd815280e837830c3e01170c6c13f6b0687d3d64   15655       running     /run/containerd/io.containerd.runtime.v1.linux/k8s.io/ccc4612d874ef21c9bd36976cd815280e837830c3e01170c6c13f6b0687d3d64   2019-07-30T07:38:25.252221456Z   root
fcf197c1366c21624a0cefe8d0975066956dfae6b1bb0bddbdbaa018354fdca4   15502       running     /run/containerd/io.containerd.runtime.v1.linux/k8s.io/fcf197c1366c21624a0cefe8d0975066956dfae6b1bb0bddbdbaa018354fdca4   2019-07-30T07:38:24.908954234Z   root


[root@master runc]# runc -root /var/run/docker/runtime-runc/moby list
ID                                                                 PID         STATUS      BUNDLE                                                                                                                 CREATED                          OWNER
3cc0ec11447cbe50dde34474e1936fb940a2c7ebb49cd6099cf70f742992f60b   7915        running     /run/containerd/io.containerd.runtime.v1.linux/moby/3cc0ec11447cbe50dde34474e1936fb940a2c7ebb49cd6099cf70f742992f60b   2019-07-28T11:07:48.327338536Z   root
cf8911b66df50d267e7bd6699dc38c2c4e5b7324ce9c9bf2108800b957035813   7892        running     /run/containerd/io.containerd.runtime.v1.linux/moby/cf8911b66df50d267e7bd6699dc38c2c4e5b7324ce9c9bf2108800b957035813   2019-07-28T11:07:48.167570109Z   root
```

`-root` 的值可以通过上面 container-shim 的 `-runtime-root`获得。

### 在 node1 上

```
[root@node01 ~]# docker ps
CONTAINER ID        IMAGE                                                                 COMMAND                  CREATED             STATUS              PORTS               NAMES
eb6574aa4f0b        quay.io/external_storage/nfs-client-provisioner                       "/nfs-client-provisi…"   45 hours ago        Up 45 hours                             k8s_nfs-client-provisioner_nfs-client-provisioner-6c8c5fb7d4-88bnx_default_14321ec0-ac56-11e9-b88b-00505699ed79_9
a6c75aa56bb5        registry.cn-hangzhou.aliyuncs.com/google-containers/pause-amd64:3.0   "/pause"                 45 hours ago        Up 45 hours                             k8s_POD_nfs-client-provisioner-6c8c5fb7d4-88bnx_default_14321ec0-ac56-11e9-b88b-00505699ed79_1
c6200aa9db3c        ac22eb1f780e                                                          "/tiller"                46 hours ago        Up 46 hours                             k8s_tiller_tiller-deploy-767d9fb945-7rjtr_kube-system_d1dd3461-af57-11e9-b88b-00505699ed79_1
3ba6a0a3bc05        registry.cn-hangzhou.aliyuncs.com/google-containers/pause-amd64:3.0   "/pause"                 46 hours ago        Up 46 hours                             k8s_POD_tiller-deploy-767d9fb945-7rjtr_kube-system_d1dd3461-af57-11e9-b88b-00505699ed79_1
cff0cdb06c7f        eb516548c180                                                          "/coredns -conf /etc…"   46 hours ago        Up 46 hours                             k8s_coredns_coredns-747b485444-r8c94_kube-system_de1d5186-a857-11e9-94c1-00505699ed79_561
c8ba17a43d5d        registry.cn-hangzhou.aliyuncs.com/google-containers/pause-amd64:3.0   "/pause"                 46 hours ago        Up 46 hours                             k8s_POD_coredns-747b485444-r8c94_kube-system_de1d5186-a857-11e9-94c1-00505699ed79_1


[root@node01 ~]# crictl version
Version:  0.1.0
RuntimeName:  docker
RuntimeVersion:  18.09.6
RuntimeApiVersion:  1.39.0

[root@node01 ~]# crictl ps
CONTAINER ID        IMAGE                                                                                                                     CREATED             STATE               NAME                     ATTEMPT             POD ID
eb6574aa4f0b4       quay.io/external_storage/nfs-client-provisioner@sha256:022ea0b0d69834b652a4c53655d78642ae23f0324309097be874fb58d09d2919   45 hours ago        Running             nfs-client-provisioner   9                   a6c75aa56bb59
c6200aa9db3cc       ac22eb1f780e4                                                                                                             46 hours ago        Running             tiller                   1                   3ba6a0a3bc05b
cff0cdb06c7f0       eb516548c180f                                                                                                             46 hours ago        Running             coredns                  561                 c8ba17a43d5d2

```

crictl 默认是连接 dockershim，而 dockershim 实际上是kubelet 在监听。 crictl help 可以看到 -r 的默认值：

```
   --runtime-endpoint value, -r value  Endpoint of CRI container runtime service (default: "unix:///var/run/dockershim.sock") [$CONTAINER_RUNTIME_ENDPOINT]
```

```

[root@node01 ~]# netstat -nlp | grep dockershim
unix  2      [ ACC ]     STREAM     LISTENING     29605    1938/kubelet         /var/run/dockershim.sock

[root@node01 ~]# crictl -r /var/run/dockershim.sock version
Version:  0.1.0
RuntimeName:  docker
RuntimeVersion:  18.09.6
RuntimeApiVersion:  1.39.0
```

因为 contianerd 没有 启用 CRI 插件，所以无法是用 crictl 连接

```
[root@node01 ~]# cat /etc/containerd/config.toml | grep cri
disabled_plugins = ["cri"]

[root@node01 ~]# crictl -r /run/containerd/containerd.sock version
FATA[0000] getting the runtime version failed: rpc error: code = Unimplemented desc = unknown service runtime.v1alpha2.RuntimeService
```

使用 ctr 只能看到 moby ns 的容器：

```
[root@node01 ~]# ctr namespaces ls
NAME LABELS
moby
```


### 在 node2 上


```
[root@node02 userdata]# ps -ef | grep crio
root     31241     1  0 15:31 ?        00:00:00 /usr/libexec/crio/conmon -s -c f9f42b5ae54c71180ab7eb1706205bba79597d019f1c3e22f5f68e0b0ae055a8 -u f9f42b5ae54c71180ab7eb1706205bba79597d019f1c3e22f5f68e0b0ae055a8 -r /usr/sbin/runc -b /var/run/containers/storage/overlay-containers/f9f42b5ae54c71180ab7eb1706205bba79597d019f1c3e22f5f68e0b0ae055a8/userdata -p /var/run/containers/storage/overlay-containers/f9f42b5ae54c71180ab7eb1706205bba79597d019f1c3e22f5f68e0b0ae055a8/userdata/pidfile -l /var/log/pods/default_busybox-54f48547c7-j9fp9_10a3ff6f-b29b-11e9-8df0-00505699ed79/f9f42b5ae54c71180ab7eb1706205bba79597d019f1c3e22f5f68e0b0ae055a8.log --exit-dir /var/run/crio/exits --socket-dir-path /var/run/crio --log-level error
root     31716     1  0 15:33 ?        00:00:12 /usr/bin/crio --runtime=/usr/sbin/runc --pause-image="registry.cn-hangzhou.aliyuncs.com/google-containers/pause-amd64:3.0"
root     31773     1  0 15:34 ?        00:00:00 /usr/libexec/crio/conmon -s -c fbe5b37ad3c472ea970af75afc4c58481c2dd4d89a93b1a7ca37ddda823b201c -u fbe5b37ad3c472ea970af75afc4c58481c2dd4d89a93b1a7ca37ddda823b201c -r /usr/sbin/runc -b /var/run/containers/storage/overlay-containers/fbe5b37ad3c472ea970af75afc4c58481c2dd4d89a93b1a7ca37ddda823b201c/userdata -p /var/run/containers/storage/overlay-containers/fbe5b37ad3c472ea970af75afc4c58481c2dd4d89a93b1a7ca37ddda823b201c/userdata/pidfile -l /var/log/pods/default_busybox-54f48547c7-j9fp9_10a3ff6f-b29b-11e9-8df0-00505699ed79/busybox/0.log --exit-dir /var/run/crio/exits --socket-dir-path /var/run/crio --log-level error -t

[root@node02 userdata]# ps -ef | grep 31773
root     31785 31773  0 15:34 ?        00:00:00 /bin/sh

```

可见 conmon 有些类似 containerd 的container-shim，作为容器进程的父进程存在。



```
crictl -r /var/run/crio/crio.sock version
Version:  0.1.0
RuntimeName:  cri-o
RuntimeVersion:  1.11.11-1.rhaos3.11.git474f73d.el7
RuntimeApiVersion:  v1alpha1

[root@node02 ~]# crictl -r /var/run/crio/crio.sock ps
CONTAINER           IMAGE                                                                                               CREATED             STATE               NAME                ATTEMPT             POD ID
fbe5b37ad3c47       docker.io/library/busybox@sha256:895ab622e92e18d6b461d671081757af7dbaa3b00e3e28e12505af7817f73649   About an hour ago   Running             busybox             0                   f9f42b5ae54c7

[root@node02 userdata]# docker ps
CONTAINER ID        IMAGE               COMMAND             CREATED             STATUS              PORTS               NAMES

[root@node02 runc]# runc list
ID                                                                 PID         STATUS      BUNDLE                                                                                                                 CREATED                          OWNER
f9f42b5ae54c71180ab7eb1706205bba79597d019f1c3e22f5f68e0b0ae055a8   31252       running     /run/containers/storage/overlay-containers/f9f42b5ae54c71180ab7eb1706205bba79597d019f1c3e22f5f68e0b0ae055a8/userdata   2019-07-30T07:31:54.768990081Z   root
fbe5b37ad3c472ea970af75afc4c58481c2dd4d89a93b1a7ca37ddda823b201c   31785       running     /run/containers/storage/overlay-containers/fbe5b37ad3c472ea970af75afc4c58481c2dd4d89a93b1a7ca37ddda823b201c/userdata   2019-07-30T07:34:15.524324699Z   root
```

docker ps 同样看不到 crio 创建的容器，而 runc 可以看到 pause 容器和主容器。

# 总结

1. 容器运行时是管理容器和容器镜像的程序。有两个标准，一个是 CRI-runtime，抽象了 kubelet 如何启动和管理容器，一个是 OCI-runtime，抽象了怎么调用内核 API 来管理容器。标准实际上是定义了一系列接口，让上层应用与底层实现接耦。

2. 实现 CRI 的 runtime 有 CRI-O、CRI-containred 等，CRI 的命令行客户端是 crictl。containerd 的客户端是 ctr。dockerd 的客户端是 docker。它们通过 unix sock 与对应的 daemon 交互。

3. OCI 的默认实现是 runc。runc 是一个命令行工具，而不是一个 daemon。通过 runc 我们可以手动启动一个容器，也可以查看其他进程启动的容器。

4. 进一步学习 runtime，可以看 runc/contianrd/cri-o 的源码。熟悉 runtime，要获取容器的相关信息会更方便，比如 metric、log。更进一步可以实现自己的 CRI/OCI runtime。



# 参考链接

[Kubernetes中的开放接口CRI、CNI、CSI](https://jimmysong.io/posts/kubernetes-open-interfaces-cri-cni-csi)

[白话 Kubernetes Runtime](https://aleiwu.com/post/cncf-runtime-landscape/)

[Docker组件介绍（一）：runc和containerd](https://jiajunhuang.com/articles/2018_12_22-docker_components.md.html)

[走进docker(04)：什么是容器的runtime?](https://segmentfault.com/a/1190000009583199)

画图工具： [asciiflow](http://asciiflow.com/)
