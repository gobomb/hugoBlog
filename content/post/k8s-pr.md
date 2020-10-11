---
title: "给 Kubernetes 提 PR"
date: 2020-10-12T02:02:25+08:00
draft: false
---

之前在解决 weave 的[问题](https://gobomb.github.io/post/debug-and-pr-for-weave/)时，顺便也发现了 K8s client-go 代码中存在的[问题](https://github.com/kubernetes/kubernetes/issues/93641) ，并提交了 [PR](https://github.com/kubernetes/kubernetes/pull/93646) ，九月份的时候终于被 merge 进 1.20 的 release，并 cherry pick 回 1.17～1.19（不过公司使用的环境是 1.16，社区不再提供官方的补丁……）

weave 因为依赖的这个库的 bug，掩盖了本应该很快发现的 bug，从而导致很多诡异的现象，我觉得这个库应用这么广泛，应该有不少开发者也受影响了才对。而且我和同事在其他项目的使用过程中，也发现过类似的现象（Process 被阻塞，不能正确处理新的事件）。但一开始在 k8s 的 issues 翻了很久，都找到没有类似的问题，实在是违反直觉。

后来仔细看了下 client-go 源码，也找到了合理的解释。informer 有两种用法，一种是使用 client-go/tools/cache/controller.go 中提供的 controller（可以说是低级别的 informer），一种是 client-go/tools/cache/shared_informer.go 中的 SharedInformer 或者 SharedIndexInformer，也就是 SharedInformerFactory 返回的 informer。 SharedIndexInformer 封装的层次更高，大部分项目都是用的后者，刚好避开了普通 informer 存在的 bug。而我们的部分项目，以及 weave-npc 都是用的 controller/低级别informer。

具体而言，bug 就是刚好发生在 controller/低级别informer 和 SharedIndexInformer 对 Contorller 接口方法 Run() 的不同实现上面。它们对 ResourceEventHandler 接口的处理方式或者说 Process 的实现是不同的，而 ResourceEventHandler 的实现就是用户业务代码发生 panic 的地方。

controller/低级别informer 中的 processLoop 和 SharedIndexInformer 中的 sharedProcessor 都是 Process： 1. 负责消费 DeltaFIFO 队列产生的事件 2. 将事件存入 cache 里 3. 根据事件调用用户实现的 ResourceEventHandler。

controller/低级别informer 只有一个 ResourceEventHandler，Run() 是直接调用 processLoop 来使用 ResourceEventHandler 的，Run() 是 processLoop 的直接调用者，panic 的传递就被错误的 defer 给拦截了 。而 SharedIndexInformer 为了支持多个 ResourceEventHandler 共用一个 Informer，用了一个 sharedProcessor 来做事件的分发（而非简单的 processLoop）。SharedIndexInformer 的 Run() 虽然会调用 controller 的 Run() 方法，但是最终调用的是 sharedProcessor 提供的 Process。 所以只要 sharedProcessor 正确处理了 panic，就不会发生和 controller 一样的问题。

一般情况下，SharedIndexInformer 确实是更推荐使用，SharedInformerFactory 已经封装好了各种资源的 informer interface，直接调用就可以，同一种资源可以添加多个 ResourceEventHandler，且可以添加各种索引加速查找，满足更复杂的需求。当然，controller/低级别informer 也有它的场景，比如说只需要一个 ResourceEventHandler、不需要复杂 index 的情况，并且 controller 的实现很简单。

在命名上，其实是有点容易混淆的：对于低级别的 informer 而言，它既是 controller ，也是 informer。而高级别的 informer，实现了 Controller 接口，还保留了旧的 controller 对象，因为它只是重写了 Process 的方式，同时复用原来 controller 的 Reflector、DeltaFIFO 实现。