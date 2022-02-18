---
title: "sharedInformer 如何实现注册多组 ResourceEventHandler"
date: 2022-02-17T20:00:57+08:00
draft: false
---

client-go 的 cache 包缓存对象数据的流向是：kube-apiserver-> reflector -> DeltaFIFO -> infomer 里的 Indexer，同时 call 用户实现的 ResourceEventHandler：

1. reflector从apiserver list全量数据，并watch 后续数据的更新，会定期进行一次全量 list，防止本地缓存与服务端不一致
2. reflector 会将 obj 写到 DeltaFIFO 中
3. DeltaFIFO 可以定时（设置了resyncPeriod的话）从 Indexer 取 key，重新入队，防止一旦 obj 在 handler  里计算失败，得不到重试的机会
4. controller 的 processLoop 循环调用 Pop 和 Process 函数， Pop 从 DeltaFIFO 取 Obj ，Process 更新 Indexer，并触发 ResourceEventHandler

普通 Informer 对同一种对象只能注册一组 ResourceEventHandler，要实现多组 ResourceEventHandler，就需要多创建 Informer，数据是一样的，会造成内存上的浪费。所以 sharedInformer 的引入，支持了针对同一类对象的 ResourceEventHandler 注册到一个 informer 上，实现数据的复用。

本文主要从[源码](https://github.com/kubernetes/client-go/tree/a7d2e0118033720853dcd4aaa50b3b971387262d)的层面，分析一下这个多组 ResourceEventHandler 的注册是怎么实现的，数据是怎样做分发的。

为了实现 sharedindexinformer 挂载多组 handler，相对普通 informer，有两点不同：一是重写了Process方法，用HandleDeltas方法替代；二是引入两个新的结构：sharedProcessor、processorListener，用于做数据分发。

processorListener 持有两个同步 channel（addCh、nextCh） 一个环形队列，和一个 ResourceEventHandler。是ResourceEventHandler的进一步包装。

sharedProcessor 持有一个 processorListener 切片。用户通过调用 AddEventHandler，将自己实现的ResourceEventHandler注册到processorListener中，并 append 到sharedProcessor中的切片中，同时通过两个goroutine启动各个processorListener的run()和pop()。

sharedIndexInformer实现了 ResourceEventHandler，并持有一个 sharedProcessor。

sharedProcessor 的 HandleDeltas 就是注册给 Controller 的 Process 函数（在启动的时候会被 processLoop 循环线程调用，用于消费 DeltaFIFO 出队的 Obj），HandleDeltas最终会调用 sharedIndexInformer 实现的默认 ResourceEventHandler。 

sharedIndexInformer 会在三组回调函数中调用 sharedProcessor.distribute。

sharedProcessor.distribute 遍历 processorListener 列表，调用每个 processorListener 的 add 方法。

这里类似观察者模式。DeltaFIFO 出队的 Obj是 Observer关心的事件，processorListener是一个个Observer，注册到 sharedProcessor。sharedProcessor负责在事件到达时，回调Observer的方法，这里就是 add。

processorListener的add 方法把对象写入 addCh。

pop()  goroutine 从 addCh 中读 Obj，写 Obj 到 nextCh，并用环形队列做缓冲协调两个channel的收发速率
run() goroutine 从 nextCh 读出 Obj，调用 processorListener 自身的、也就是用户实现、注册的 ResourceEventHandler


为啥 processorListener 需要两个同步 channel、一个环形队列、两个 goroutine 才能消费 Obj呢？因为接收和消费的速率不一致，中间就需要缓冲，不然消费速率太慢会阻塞接收。


pop() 函数值得一提，这种写法我第一次见到：用 nil channel 来控制 for-select 中某个 case的开启和关闭。

pendingNotifications是一个环形队列，用来做缓冲。代码注释里用1.2.3.4来说明每个语句执行的顺序。

```go
func (p *processorListener) pop() {
	defer utilruntime.HandleCrash()
	// 7. 通过close(p.nextCh)来关闭 run 线程
	defer close(p.nextCh) 

	var nextCh chan<- interface{}
	var notification interface{}
	for {
		select {
		// 0. 当 nextCh 为nil时，写到 nil channel 会阻塞，所以不会被 select到
		// 4.2（4.1和4.2会随机执行到一个） notification 发送成功
		case nextCh <- notification:
			var ok bool
			// 5 更新notification为缓冲队列里的一个，等待下次 select 到这个 case 就可以发送了
			notification, ok = p.pendingNotifications.ReadOne()
			if !ok { 
				// 6 在环形缓冲区中读不到数据，都发送完了，把nextCh置为nil
				// 相当于关闭这个 case
				nextCh = nil 
			}
		// 0 p.addCh开始有消息到达，一开始会命中这个case
		case notificationToAdd, ok := <-p.addCh:
			// 如果ok==false，说明 addCh被关闭，直接返回
			if !ok {
				return
			}
			// 1. 一开始 notification是nil，nextCh也是nil，必然会先走到这里，环形队列也是空的
			// 6. 缓冲区没有数据了， nextCh也只为 nil（case1 被关闭），重新回到1
			if notification == nil { 
				// 2. 直接设置 notification ，不需要发到缓冲区，直接发到nextCh
				// 	  跟异步 channel  通知 goroutine 队列出队的实现模式有点类似
				notification = notificationToAdd
				// 3. 启动第一个case，允许发送
				nextCh = p.nextCh
			} else { 
			     // 4.1（4.1和4.2会随机执行到一个） notification 不为空，说明第一个 case 可用，
				 //     已经有notification要发送了，但因为 for-select的随机选择 select 到这个 case
			     //     就将新的 notificationToAdd 写到环形队列里缓冲起来
				p.pendingNotifications.WriteOne(notificationToAdd)
			}
		}
	}
}

```

这里乍一看两个case都操作了 nextCh 、notification 这两个变量，似乎应该加锁。其实是因为两个case总是交替执行，不会有竞争。类似一个单线程轮询器。

通过关闭某个 channel，来通知读该 channel 的 goroutine 结束，这也算是常见的模式了。

整个流程总结一下就是： 

1. DeltaFIFO 出队会先调用 sharedIndexInformer 的默认 ResourceEventHandler，在这里再调用 sharedProcessor 的 distribute 方法进行 Obj 的分发
2. obj 会被发到 sharedProcessor 里注册的每个 processorListener 的 addCh 中
3. processorListener 的 pop 线程消费addCh，同时用环形队列做缓冲，然后转发到nextCh 中
4. processorListener 的 run 线程消费 nextCh ，最终调用用户实现的ResourceEventHandler，把 Obj 发到用户函数做处理

