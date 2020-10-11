---
title: "给 WeaveNet 社区提 PR"
date: 2020-08-16T00:45:01+08:00
draft: false
---

任职的公司 K8s 集群网络插件用的是 [WeaveNet](https://www.weave.works/oss/net/)。WeaveNet 是一套基于 VXLAN 的容器网络方案。我们还用了 weave-npc 作为 K8s NetworkPolicy 的实现。从 2.6.0 版本开始，weave 存在一个很严重的 bug，会导致新创建的 pod 所有的网络流量被丢弃，在我们开发、测试、生产环境 K8s 集群里有很大的概率被触发。本文主要记录如何定位到该 bug 以及如何修复，给 weave 上游提 Pull Request 并被接受的过程。

## 现象及复现
K8s 集群使用 weave-kube 和 weave-npc 2.6.0～2.6.5 版本。创建一个 namespace，在此 namespace 下创建 2 到 3 个 deploymnet，同时每个 deployment 创建一个 networkpolicy，允许网络流量的进出。在这种配置下，该 deployment 关联的 pod 是能够访问到 networkpolicy 放行的 IP 的。

在一切部署完成后，删除该 namespace `kubectl delete namespace [ns name]` 。重复此操作 n 次，会发现，新创建的 pod 的所有网络访问都不通了，包括 networkpolicy 所允许的。

weave-kube 和 weave-npc 都是作为 daemonset 部署的。查看 pod 所在 node 上的 weave-npc 的日志，可以看到大量的 pod 对应的流量被 block 的日志。

在 weave 的 github 仓库，我提了[issue](https://github.com/weaveworks/weave/issues/3836) 描述了现象和详细的复现方法。

## 定位问题过程
检查 weave-npc 的日志，发现在 weave-npc 在处理 pod 删除事件的时候，有 panic 字样，且打出了完整的调用栈信息：

```
DEBU: 2020/07/28 09:58:33.806374 EVENT DeletePod {"metadata":{"creationTimestamp":"2020-07-28T09:57:35Z","deletionGracePeriodSeconds":0,"deletionTimestamp":"2020-07-28T09:58:33Z","generateName":"bp-s1-569648b84-","labels":{"App":"f2f83717edc2c4009874aa423409ecd08","Blueprint":"bbp-s1","Service":"bp-s1","app":"bp-s1","flowid":"47","pod-template-hash":"569648b84","version":"v1"},"name":"bp-s1-569648b84-jltfv","namespace":"f2f83717edc2c4009874aa423409ecd08","resourceVersion":"11867380","selfLink":"/api/v1/namespaces/f2f83717edc2c4009874aa423409ecd08/pods/bp-s1-569648b84-jltfv","uid":"f990ffe2-227f-4b3e-a1e5-e0f7d59e7c49"},"spec":{"affinity":{},"containers":[{"image":"harbor.cloud2go.cn/cloudtogo/network-multitool","imagePullPolicy":"Always","name":"bp-s1","ports":[{"containerPort":80,"name":"p80","protocol":"TCP"}],"readinessProbe":{"failureThreshold":3,"initialDelaySeconds":1,"periodSeconds":5,"successThreshold":1,"tcpSocket":{"port":80},"timeoutSeconds":1},"terminationMessagePath":"/dev/termination-log","terminationMessagePolicy":"FallbackToLogsOnError"}],"dnsConfig":{"options":[{"name":"ndots","value":"1"}]},"dnsPolicy":"ClusterFirst","nodeName":"n1.ha.env.lab.io","restartPolicy":"Always","schedulerName":"default-scheduler","securityContext":{},"serviceAccount":"default","serviceAccountName":"default","terminationGracePeriodSeconds":0},"status":{"conditions":[{"lastProbeTime":null,"lastTransitionTime":"2020-07-28T09:57:35Z","status":"True","type":"Initialized"},{"lastProbeTime":null,"lastTransitionTime":"2020-07-28T09:57:38Z","status":"True","type":"Ready"},{"lastProbeTime":null,"lastTransitionTime":"2020-07-28T09:57:38Z","status":"True","type":"ContainersReady"},{"lastProbeTime":null,"lastTransitionTime":"2020-07-28T09:57:35Z","status":"True","type":"PodScheduled"}],"hostIP":"10.10.13.46","phase":"Running","podIP":"10.20.128.40","qosClass":"BestEffort","startTime":"2020-07-28T09:57:35Z"}}
INFO: 2020/07/28 09:58:33.806394 deleting entry 10.20.128.40 from weave-hkFEnqOYZ~#jp*[N$?})[#4t3 of f990ffe2-227f-4b3e-a1e5-e0f7d59e7c49
INFO: 2020/07/28 09:58:33.806403 deleting entry 10.20.128.40 from weave-e$G8cjWOPOD!AV1BHcQc@]W7T of f990ffe2-227f-4b3e-a1e5-e0f7d59e7c49
INFO: 2020/07/28 09:58:33.806410 deleting entry 10.20.128.40 from weave-6t$=mTtRDZ$mqByw*5EuD[!%6 of f990ffe2-227f-4b3e-a1e5-e0f7d59e7c49
INFO: 2020/07/28 09:58:33.806418 deleted entry 10.20.128.40 from weave-6t$=mTtRDZ$mqByw*5EuD[!%6 of f990ffe2-227f-4b3e-a1e5-e0f7d59e7c49
ERROR: logging before flag.Parse: E0728 09:58:33.807381    7656 runtime.go:66] Observed a panic: "invalid memory address or nil pointer dereference" (runtime error: invalid memory address or nil pointer dereference)
/go/src/github.com/weaveworks/weave/vendor/k8s.io/apimachinery/pkg/util/runtime/runtime.go:72
/go/src/github.com/weaveworks/weave/vendor/k8s.io/apimachinery/pkg/util/runtime/runtime.go:65
/go/src/github.com/weaveworks/weave/vendor/k8s.io/apimachinery/pkg/util/runtime/runtime.go:51
/usr/local/go/src/runtime/panic.go:679
/usr/local/go/src/runtime/panic.go:199
/usr/local/go/src/runtime/signal_unix.go:394
/go/src/github.com/weaveworks/weave/npc/namespace.go:336
/go/src/github.com/weaveworks/weave/npc/controller.go:144
/go/src/github.com/weaveworks/weave/npc/controller.go:106
/go/src/github.com/weaveworks/weave/npc/controller.go:143
/go/src/github.com/weaveworks/weave/prog/weave-npc/main.go:294
/go/src/github.com/weaveworks/weave/vendor/k8s.io/client-go/tools/cache/controller.go:209
/go/src/github.com/weaveworks/weave/vendor/k8s.io/client-go/tools/cache/controller.go:320
/go/src/github.com/weaveworks/weave/vendor/k8s.io/client-go/tools/cache/delta_fifo.go:444
/go/src/github.com/weaveworks/weave/vendor/k8s.io/client-go/tools/cache/controller.go:150
/go/src/github.com/weaveworks/weave/vendor/k8s.io/apimachinery/pkg/util/wait/wait.go:133
/go/src/github.com/weaveworks/weave/vendor/k8s.io/apimachinery/pkg/util/wait/wait.go:134
/go/src/github.com/weaveworks/weave/vendor/k8s.io/apimachinery/pkg/util/wait/wait.go:88
/go/src/github.com/weaveworks/weave/vendor/k8s.io/client-go/tools/cache/controller.go:124
/usr/local/go/src/runtime/asm_amd64.s:1357
```

通过调用栈信息，我们可以去检查 weave-npc 的源码，确定错误的根源。从 panic 的信息看： `runtime error: invalid memory address or nil pointer dereference` ，是典型的空指针错误。

在分析了 weave-npc 的代码后，我发现这是一个并发情况下，顺序不一致的问题。

weave-npc 的原理是：使用了 K8s 官方的 go 客户端库 client-go 实现，作为一个 controller 运行在 K8s 中（和 K8s 其他的 controller 一样），建立对 namespace、pod、networkpolicy 这几个对象的 informer，通过关注并响应 ns、pod、netpol 对象的增删改事件作出对应的操作，即修改 iptables 规则，把 pod ip 加到规则关联的 ipset 之中，来达到对 pod 或者 service 的访问控制。默认情况下，所有的网络流量都是会被 drop 的，只有 netpol 显式放行，流量才可以通过。也就是白名单。

namespace、pod、networkpolicy 这几个对象的 informer，分别是作为三个 goroutine 启动的，也就是说，是并发的。绑定在 namespace 和 pod 对象上的 handler，有可能修改同一个数据结构。在这个场景下，namespace handler 和 pod handler 都持有 namespace 对象的指针。用户删除 namespace 时，默认情况下，K8s 会保证该 namespace 下的所有资源被删除，才删除 namespace 对象本身。weave-npc 也是基于这个假设来设计的。

但是，K8s 虽然会保证`对象`的删除顺序，但不保证`删除事件`的顺序。因为网络的问题，两个不同对象的删除事件 到达的顺序，有可能被打乱，kube-apiserver 和 weave-npc 毕竟是两个 node 上的两个进程，这里有个同步的问题。另外，namespace informer 和 pod informer 之间也是并发的，他们对 namespace event 和 pod event 的`消费速度`也不一样。即使事件按照顺序到达客户端（weave-npc），客户端也未必会严格按照`事件到达顺序`来消费事件（即触发 handler）。

于是，本应该先执行 pod delete handler（引用了 namespace 指针）再执行 namespace delete handler（将 namespace 指针置为 nil），有很大概率（毕竟集群中存在大量删除操作，规模越大越频繁）变成，先执行 namespace delete handler（将 namespace 指针置为 nil），再执行 pod delete handler（引用了空指针，引发 panic）。

所以，解决方法就是避免对空指针的引用。阅读了源码之后，发现 namespace 对象指针并没有使用的必要，需要使用的数据是 namespace 的 UID 和 Labels，我把 UID 和 Labels 的值给复制出来，不再使用 namespace 指针，从而避免了 panic 发生的可能。

我给 weave 社区提交了 [Pull Request](https://github.com/weaveworks/weave/pull/3833) ，并且被愉快地接受了。最新发布的 [2.7.0](https://github.com/weaveworks/weave/releases/v2.7.0) 已经包含了这个 fix。

在这里，还有一个令人困惑的点：显然程序 panic 了，但 panic 之后，程序应该退出，然后由外部的进程管理工具重启程序或者容器（在这个环境下，就是由 K8s 负责拉起容器）。weave-npc 除了在日志打印调用栈以外，并没有如预期退出重启，仍然以错误的状态运行，从而使后续的新 pod 的网络不正常。

我怀疑是 client-go 的问题。panic 发生在 weave-npc 注册给 informer 的事件处理 handler 里。handler 的调用发生在 client-go 的库代码里，显然这个 panic 应该是在某一步被 recover 或者阻塞了，从上述的调用栈日志，也可以看出 panic 一步步循着调用栈往上传递，中间经过大量的 client-go 的代码。

在 client-go 的代码中，我发现了问题所在，panic 会被 defer 函数中的代码阻塞：

```
// code in k8s.io/client-go/tools/cache/controller.go
func (c *controller) Run(stopCh <-chan struct{}) {
    defer utilruntime.HandleCrash()
    go func() {
        <-stopCh
        c.config.Queue.Close()
    }()
    r := NewReflector(
        c.config.ListerWatcher,
        c.config.ObjectType,
        c.config.Queue,
        c.config.FullResyncPeriod,
    )
    r.ShouldResync = c.config.ShouldResync
    r.clock = c.clock
    if c.config.WatchErrorHandler != nil {
        r.watchErrorHandler = c.config.WatchErrorHandler
    }

    c.reflectorMutex.Lock()
    c.reflector = r
    c.reflectorMutex.Unlock()

    var wg wait.Group
    defer wg.Wait()                                 // <-- 2. panic传递出来后， defer 会被调用，且会被 wg.Wati() 阻塞

    wg.StartWithChannel(stopCh, r.Run)

    wait.Until(c.processLoop, time.Second, stopCh)  // <-- 1. weave-npc的事件处理代码会在 c.processLoop 被调用，panic 也会从此传递出来
}
```

weave-npc 会调用以上函数来启动 informer，这个函数主要是启动对 kube-apiserver 数据和事件的同步（`r.Run`），同时启动一个循环，在事件到来的时候调用已经注册好的 handler 方法（`c.processLoop`）。

这里用了一些技巧来保证不同 goroutine 的顺序：r.Run 是一个新的 goroutine，通过用 wait.Group 来让它只依赖于 stopCh，只有在 stopCh 有消息，r.Run 才会结束。但是这里没有考虑到 panic 的情况。按照 go 的设计，panic 发生后，会在当前的 goroutine 层层往上传递，并且执行 defer 函数，直到顶层，结束整个进程。假如 defer 函数中有 recover，则 panic 可以被捕获处理。这里 `defer wg.Wait()` 在 panic 的情况会被调用，但因为 stopCh 没有收到消息，会导致永远阻塞，panic 也无法再继续向上传递，结束进程了。从 weave-npc 的角度看，就是这个 informer 已经不正常了，c.processLoop 不再响应 pod 事件，iptables / ipset 不再被更新，新 pod 网络因此受到了影响（不再有机会把 pod ip 加到白名单中）。而此时如果重启 weave-npc 进程，一切则可恢复正常。

我也将此现象反映给了 K8s 社区，提交了 [issue](https://github.com/kubernetes/kubernetes/issues/93641) ，同时也提交了我的 [PR](https://github.com/kubernetes/kubernetes/pull/93646) 。

## 总结
1. 在分布式的环境下，要充分考虑并发、顺序可能带来的问题。在 K8s 这种最终一致性的系统，更加要谨慎一些。
2. 要深刻理解 go 中 panic、recover、defer 机制的原理，对这几个特性有可能遇到的坑要更敏感些。
3. 在调试代码的过程中，尝试了用 devel 在线查看 go 进程的栈帧。对于用户业务代码、库代码、go runtime 代码之间的调用和关系，有了更感性的认知。而且，调用栈是更加实在的“证据”，在社区交流中，能够提供很充分的信息。


