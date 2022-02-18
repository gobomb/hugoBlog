---
title: "Informer Resync 做了什么"
date: 2022-02-19T01:42:09+08:00
draft: false
---

1. resync 不是 re-list。

2. resync 是重放 informer 中的 obj 到 DeltaFIFO 队列中，触发 handler 再次处理 obj。

    目的是防止有些 handler 处理失败了而缺乏重试的机会。特别是，需要修改外部系统的状态的时候，需要做一些补偿的时候。

    比如说，根据 networkpolicy刷新 node 上的 iptables。

    iptables 有可能会被其他进程或者管理员意外修改，有 resync 的话，才有机会定期修正。

    这也说明，回调函数的实现需要保证幂等性。对于 OnUpdate 函数而言，有可能会拿到完全一样的两个 Obj，实现 OnUpdate 时要考虑到。

3. re-list 是指 reflector 重新调用 kube-apiserver 全量同步所有 obj。但目前(v1.20)没有显式配置 re-list 周期的参数。

    官方开发者似乎觉得不需要 re-list，目前的方式已经[足够可靠](https://groups.google.com/g/kubernetes-sig-api-machinery/c/PbSCXdLDno0#:~:text=We%20don%E2%80%99t%20do%20re-lists%20because%20we%20have%20the%20confidence%20in%20the%20data%20store%2C%20but%20earlier%20in%20the%20project%20we%20were%20less%20confident.)

    list 的时机一般是在程序第一次启动，或者 watch 有错误，才会 re-list。

    具体什么时候会发生 re-list？这里有篇博客可以[参考](https://www.cnblogs.com/orchidzjl/p/15086027.html)


4. 如何配置 resync 的周期？ 

    `func NewSharedIndexInformer(lw ListerWatcher, exampleObject runtime.Object, defaultEventHandlerResyncPeriod time.Duration, indexers Indexers)`

    第三个参数 defaultEventHandlerResyncPeriod 就指定多久 resync 一次。如果为0，则不 resync。

    `AddEventHandlerWithResyncPeriod`也可以给单独的 handler 定义 resync period，否则默认和 informer 的是一样的。

5. resync 是一个水平触发的模式。

    水平触发是只要处于某个状态，就会一直通知。比如在这里，对象已经在缓存里，会触发不止一次回调函数。
    
    边缘触发是一旦发生变化，就只通知一次。但这个通知被错过了，就不再通知，直到下次变化。

    在操作系统 I/O 中，也有边缘触发和水平触发的例子。select/poll 是水平触发的，epoll 默认是水平触发，也有边缘触发模式。

    I/O 水平触发的体现就是文件描述符对应的内核缓冲区有数据，就会一直通知调用者，直到数据被处理完（有数据的状态变成无数据的状态）

    边缘触发就是，文件描述符上有数据到了，只通知一次，后面就算没有处理完，也不会再通知了。

6. 那 process 函数怎么区分从 DeltaFIFO 里拿到的 obj 是新的还是重放的呢？

    根据 obj 的 key（namespace/name）从 index 里拿到旧的 obj，和新出队的 obj 比较 resource revision，这两个 resource revision 如果一样，就是重放的，如果不一样，就是从 kube-apiserver 拿到的新的。因为 resource revision 只有在 etcd 才能更新。 index 作为客户端缓存，这个值是不变的。

7. sharedInformer 如何实现 Resync

    把需要 resync（resync 的周期到了） 的 listeners 数组复制一份到 syncingListeners，在 distribute 中， 会调用 syncingListeners 的 add 函数，触发 syncingListeners 上的回调函数

8. resync 多久一次比较合适？或者需不需要 resync？

    根据具体业务场景来，刷新iptables规则，刷新路由表，或者写入到外部数据库，都要具体分析。根据外部状态是不是稳定的、是否需要做这个补偿来决定。