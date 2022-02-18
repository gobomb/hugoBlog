---
title: "K8s client-go 源码阅读笔记"
date: 2020-10-12T00:53:25+08:00
draft: false
---

我们可以通过 list 和 watch 的机制向 k8s 的 apiserver 同步 k8s 资源对象和对象的变化。client-go 是官方提供的 apiserver go 客户端库，封装了对 
k8s 对象的操作，实现了一个 apiserver 的缓存。这篇笔记主要在 interface 的层面介绍一下 cache 包的结构。interface 构成不同业务逻辑的边界，调用往往都通过 interface 中的方法来进行，作为调用方只需要关心抽象行为，而不用关心具体实现。通过学习 client-go 的代码，也可以了解 interface 的最佳实践。从 interface 入手，可以快速了解整套代码的骨架。

client-go 实现了一个缓存，定期同步和 apiserver / etcd 中的数据，并且提供了一组响应资源变化的回调函数。作为库的用户只要实现回调函数，处理自己关心的资源对象（如Pod、Deployment、自己实现的 CR 等等），而不需要关心和 apiserver 具体的交互逻辑（list and watch）。相当于一个编程框架，让开发者专注于自己的业务逻辑而不是重复实现通用的轮子。

以下通过几个重要的概念来介绍 client-go cache 包（位于 [kubernetes/staging/src/k8s.io/client-go/tools/cache/](https://github.com/kubernetes/kubernetes/tree/master/staging/src/k8s.io/client-go/tools/cache) 基于 `1c5be7dd5046fba8733f44618fd28fbb79e7db07` ）的机制，名词后面的括号说明这个名词是interface还是struct：


1. ClientSet（struct）：封装了 k8s 所有资源对象的获取方式，实现了每一种对象的 list 和 watch 接口，可以通过 http 跟 apiserver 交互。实现了 ListerWatcher 接口。
2. ListerWatcher（interface）：

    list 就是 apiserver 一次性获取全量的数据，watch 就是持续获取增量数据

3. Controller（interface）：驱动 informer，这里负责做两件事情（Run方法） ：
    1. 通过 Reflector，调用 apiserver 将 etcd 中的对象同步到本地的 Queue 中；
    2. 启动一个processLoop goroutine 根据 Queue 弹出（Pop方法）的对象和变化类型（Delta），更新cache（ThreadSafeStore），并调用 ResourceEventHandler 中用户实现的增删改方法。

    ```go
    type Controller interface {
            Run(stopCh <-chan struct{})
            HasSynced() bool
            LastSyncResourceVersion() string
    }
    ```

4. informer（struct）：普通的informer，实现了Controller。一个informer实例关注一种对象资源。只能绑定一个 ResourceEventHandler。
5. SharedInformer（interface ）：可以看到，这里包含了和Controller一模一样的方法集，所以实现了SharedInformer的struct也同时实现了Controller。SharedInformer可以添加多个 ResourceEventHandler ，可以分发 Queue 产生的事件到多个 handler上。所谓的 share 是指多个 handler 共用一个 Informer

    ```go
    type SharedInformer interface {
        AddEventHandler(handler ResourceEventHandler)
        AddEventHandlerWithResyncPeriod(handler ResourceEventHandler, resyncPeriod time.Duration)
        GetStore() Store
        GetController() Controller
        Run(stopCh <-chan struct{})
        HasSynced() bool
        LastSyncResourceVersion() string
        SetWatchErrorHandler(handler WatchErrorHandler) error
    }
    ```

6. SharedIndexInformer（interface）：定义中包含了SharedInformer，实现了SharedIndexInformer也同时实现了SharedInformer和Controller。相当于在原来的informer功能基础上又作出了拓展，增加了索引相关的功能。

    ```go
    type SharedIndexInformer interface {
        SharedInformer
        AddIndexers(indexers Indexers) error
        GetIndexer() Indexer
    }
    ```

7. SharedInformerFactory（interface）：位于 kubernetes/staging/src/k8s.io/client-go/informers，定义了不同对象资源的 Informer 接口。Start将启动所有的informer。

    ```go
    type SharedInformerFactory interface {
        internalinterfaces.SharedInformerFactory
        ForResource(resource schema.GroupVersionResource) (GenericInformer, error)
        WaitForCacheSync(stopCh <-chan struct{}) map[reflect.Type]bool

        Admissionregistration() admissionregistration.Interface
        Internal() apiserverinternal.Interface
        Apps() apps.Interface
        Autoscaling() autoscaling.Interface
        Batch() batch.Interface
        Certificates() certificates.Interface
        Coordination() coordination.Interface
        Core() core.Interface
        Discovery() discovery.Interface
        Events() events.Interface
        Extensions() extensions.Interface
        Flowcontrol() flowcontrol.Interface
        Networking() networking.Interface
        Node() node.Interface
        Policy() policy.Interface
        Rbac() rbac.Interface
        Scheduling() scheduling.Interface
        Storage() storage.Interface
    }

    // 位于 kubernetes/staging/src/k8s.io/client-go/informers/internalinterfaces
    // SharedInformerFactory a small interface to allow for adding an informer without an import cycle
    type SharedInformerFactory interface {
        Start(stopCh <-chan struct{})
        InformerFor(obj runtime.Object, newFunc NewInformerFunc) cache.SharedIndexInformer
    }
    ```

8. Reflector（struct）：通过 ListerWatcher（ClientSet） 调用 list 和 watch，将对象数据同步到 Queue 里面。构造 Reflector 需要传入 ListerWatcher 和 Store 接口。
9. Store（interface）：提供一组对象在 cache（一个 map）中增删查改的方法

    ```go
    type Store interface {
        Add(obj interface{}) error
        Update(obj interface{}) error
        Delete(obj interface{}) error
        List() []interface{}
        ListKeys() []string
        Get(obj interface{}) (item interface{}, exists bool, err error)
        GetByKey(key string) (item interface{}, exists bool, err error)
        Replace([]interface{}, string) error
        Resync() error
    }
    ```

10. ResourceEventHandler（interface）：由库的用户实现，用来响应对象的增删改事件

    ```go
    type ResourceEventHandler interface {
        OnAdd(obj interface{})
        OnUpdate(oldObj, newObj interface{})
        OnDelete(obj interface{})
    }
    ```

11. Queue（interface）：拓展了 Store，提供了一个 Pop 方法用来 Process 方法（调用ResourceEventHandler）。也实现了 Store 接口，因为底层有 `items map[string]interface{}` 这样的结构，所以操作 map 适用 Store 的操作。除了持有一个 items，还持有一个`queue []string`，用 slice 实现了一个队列，元素就是 map 的 key，按照先来先到的顺序存放和消费。 

    ```go
    type Queue interface {
        Store
        Pop(PopProcessFunc) (interface{}, error)
        AddIfNotPresent(interface{}) error
        HasSynced() bool
        Close()
    }

    ```

12. DeltaFIFO（struct）：是一个 Queue 的实现。生产者是 Reflector ，消费者是 Pop 方法的调用者。Queue 还有另一个实现，叫 FIFO，FIFO 的 items 的值没有经过 Delta 的包装 。Delta 是变化的意思。 

    定义了另一个 struct 用来封装对象，带有变化的类型 DeltaType（Added/Updated/Deleted/Replaced/Sync）：

    ```go
    type Delta struct {
        Type   DeltaType
        Object interface{}
    }
    ```

13. Indexer（interface）：实现了Store的同时，给 cache 中的对象建立索引，方便快速地获取对象

    ```go
    type Indexer interface {
        Store
        Index(indexName string, obj interface{}) ([]interface{}, error)
        IndexKeys(indexName, indexedValue string) ([]string, error)
        ListIndexFuncValues(indexName string) []string
        ByIndex(indexName, indexedValue string) ([]interface{}, error)
        GetIndexers() Indexers
        AddIndexers(newIndexers Indexers) error
    }
    ```

    有几个重要的概念，很容易混淆：

    ```go
    type Index map[string]sets.String

    type Indexers map[string]IndexFunc

    type Indices map[string]Index

    type IndexFunc func(obj interface{}) ([]string, error)
    ```

    1. Index：通过用户自定义的 indexFunc 对 obj 计算出来的 key 和 obj的 key（通过 `MetaNamespaceKeyFunc()` 计算出来，默认是 `namespace/name`/`name`） 的集合（会有多个）的映射。
    2. Indexers：存储 Index 类型名和 IndexFunc 的映射
    3. Indices：存储 Index 类型名和对应类型的 Index 的映射
    4. IndexFunc：计算 obj 用于索引的 key。由用户自己实现，并注册到 Indexers
    5. Store 的数据结构一般是个 `items map[string]interface{}`，键是 `MetaNamespaceKeyFunc()` 产生的 key，值是对象指针，每次更新 Store 也会更新几个 Index
14. ThreadSafeStore（interface）：线程安全的 Store，实现了此接口也意味着实现了 Store 和 Indexer。

    ```go
    type ThreadSafeStore interface {
        Add(key string, obj interface{})
        Update(key string, obj interface{})
        Delete(key string)
        Get(key string) (item interface{}, exists bool)
        List() []interface{}
        ListKeys() []string
        Replace(map[string]interface{}, string)

        Index(indexName string, obj interface{}) ([]interface{}, error)
        IndexKeys(indexName, indexKey string) ([]string, error)
        ListIndexFuncValues(name string) []string
        ByIndex(indexName, indexKey string) ([]interface{}, error)
        GetIndexers() Indexers
        AddIndexers(newIndexers Indexers) error

        Resync() error
    }
    ```

简单来讲，总的流程是 Reflector 通过 ClientSet 从 apiserver 获取数据，数据被同步到 DeltaFIFO 队列里，DeltaFIFO Pop 出数据，被 Informer 消费：存入 ThreadSafeStore，并触发 ResourceEventHandler。

有几个比较难懂的概念，我花了很长时间才搞明白：

1. SharedInformer：一开始我能理解 informer 的机制，但是看不懂 ShareInformer 到底是在 share 什么，与一般的 informer 到底有什么区别。一开始以为是不同的 informer share 同一个 cache 或者同一个 queue，实际上不是。后来观察 SharedInformer 的方法，多了 AddEventHandler，说明可以添加多组 handler， 而普通的 informer 只能注册一个handler。多组 handler share 针对同一个对象的 informer。 SharedInformer 的实现也有一大部分代码是在处理如何分发事件和管理 handler。
2. index：和 index 相关有几个 map：Index、Indexes、Indices，名称相近，十分令人费解。实际上是为了支持多种 index 算法或者种类。这里的 index 思想，有点像数据库 innodb 的聚集索引和非聚集索引，cache 里的 map，存了主键（`namespace/name`）和 obj 指针，对应于聚集索引；cache 里的多个 index，存的是索引以及主键列表，相当于非聚集索引，在 index 里要查到 obj，需要“回表”查一次。
3. Store：为何有那么多种 store 的接口和实现（Queue、cache、index、FIFO、DeltaFIFO……）？他们之间是什么关系，各自又有什么目的？cache 是 Store 和 Indexer 的实现，底层是一个 ThreadSafeStore，Indexer/Queue 嵌套了 Store，DeltaFIFO 和 FIFO 实现了 Queue 和 Store。全部的 obj 存在 cache 中；queue 是队列，存的是变化的部分 obj，最后会更新到 cache 里。

Ref：

[kubernetes/staging/src/k8s.io/client-go/tools/cache/](https://github.com/kubernetes/kubernetes/tree/master/staging/src/k8s.io/client-go/tools/cache)

[深入浅出kubernetes之client-go的SharedInformer](https://blog.csdn.net/weixin_42663840/article/details/81699303)

[client-go 之 Indexer 的理解](https://mp.weixin.qq.com/s/xCa6yZTk0X76IZhOx6IbHQ)


2022.2.18 UPDATE

1. 