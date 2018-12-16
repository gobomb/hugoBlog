---
title: "ngrok 1.X 源码解析(WIP)"
date: 2018-12-17T02:08:25+08:00
draft: false
description: "通过 ngrok 源码学习 go 的典型用法"
lastmod: 2018-12-17
keywords: [golang]
tags: [golang,源码,网络编程,goroutine,channel]
categories: [技术文章]
---

## 背景

[ngrok](https://github.com/inconshreveable/ngrok)是我第一次接触的 go 项目，也是我第一个完整阅读过源码的开源项目。一开始读代码我还是 go 语言零基础，只写过一点点 Web 后端 API，读了好几个月，后面还趁着做毕业设计的机会跟着重新敲了一遍，所以我从中收获了不少东西，一直都想写一篇文章总结一下我对这套代码的理解。

ngrok 的目的是将本地的端口反向代理到公网，让你通过访问公网某个机器，经过流量的转发，访问到内网的机器。这个事情你可以有不同的叫法：反向代理、端口转发（映射）、内网穿透[^1]……原理其实不难，解决的需求也简单。

一方面，我们个人的设备一般都在 NAT 后面，不能被公网设备直接访问到，内网机器可以主动向公网发起连接，但公网不能穿过 NAT 访问到内网机器；另一方面，因为我国特有的政策，获得公网 IP 和域名想对而言要付出额外的成本。ngrok 就很适合临时暴露内网服务的场景。在程序员常聚集的 V2EX，经常能看到问怎么做内网穿透的月经贴。当然，现在大家都用 [frp](https://github.com/fatedier/frp)了，ngrok 2.0 闭源，而 frp 是中国人搞的，增加了很多新的功能，使用体验也比 ngrok 好很多。

## 项目结构

来看一下 ngrok 整个项目的结构（忽略掉了一些不必要的文件）

```
.
├── ...
├── assets							// 存放 web 静态文件和 tls 文件
│   ├── ...
└── src
    └── ngrok
        ├── cache
        │   └── lru.go
        ├── client
        │   ├── cli.go
        │   ├── config.go
        │   ├── controller.go
        │   ├── debug.go
        │   ├── main.go
        │   ├── metrics.go
        │   ├── model.go
        │   ├── mvc
        │   │   ├── ...
        │   ├── release.go
        │   ├── tls.go
        │   ├── update_debug.go
        │   ├── update_release.go
        │   └── views				// view 层包括 Web 和终端 
        │   │   ├── ...
        ├── conn						// tcp 连接相关的操作：标记连接的类型（http/tcp），发起监听（Listen）、发起主动连接（Dial），以及关键的交换两个连接的数据（Join）
        │   ├── conn.go
        │   └── tee.go
        ├── log						// 日志
        │   └── logger.go
        ├── main
        ├── msg						// 消息的序列化和反序列化
        │   ├── conn.go
        │   ├── msg.go
        │   └── pack.go
        ├── proto					// 主要被 cli/model.go 调用
        │   ├── http.go
        │   ├── interface.go
        │   └── tcp.go
        ├── server
        │   ├── cli.go				// 命令行参数的解析
        │   ├── control.go			// control 的注册、代理连接的注册
        │   ├── http.go				// http 的监听和处理
        │   ├── main.go				// 程序入口：各资源池的初始化、监听控制连接和代理连接
        │   ├── metrics.go			// 性能数据统计
        │   ├── registry.go		// tunnel/control 池的维护、tunnel/control 实例的增删查
        │   ├── tls.go				// 读取 tls 配置
        │   └── tunnel.go			// tunnel 的创建和关闭、实现公有连接和代理连接之间的匹配
        ├── util
        │   ├── broadcast.go		// 被客户端的 MVC 模型用来更新数据
        │   ├── errors.go			// 错误处理
        │   ├── id.go				// 唯一 ID 的生成
        │   ├── ring.go				// 
        │   └── shutdown.go		// 通过锁、channle、defer实现的关闭机制
        └── version
            └── version.go			// 输出版本号

```

## 服务端代码

来看一下服务端 ngrokd 的关键代码：

```go
func Main() {
	...
	// init tunnel/control registry
	registryCacheFile := os.Getenv("REGISTRY_CACHE_FILE")
	// 初始化 tunnelRegistry 用来注册 tunnel
	tunnelRegistry = NewTunnelRegistry(registryCacheSize, registryCacheFile)
	// 初始化 controlRegistry 用来注册多个客户端
	controlRegistry = NewControlRegistry()

	// 初始化一个监听池，保证可以通过协议名来找到对应的监听
	listeners = make(map[string]*conn.Listener)
	...
	// 监听来自公网的http请求。https 和 http 的逻辑是类似的，只是多了一个加载 tls 配置的步骤，这里就先省略 https 的部分。
	if opts.httpAddr != "" {
		listeners["http"] = startHttpListener(opts.httpAddr, nil)
	}
	...
	// 监听控制连接和建立代理连接的请求
	tunnelListener(opts.tunnelAddr, tlsConfig)
	}
```

在这里一个 control 对应一个 ngrok 客户端，这个客户端可能处于不同的 NAT，会主动连接 tunnelAddr 端口，向服务端建立控制连接，注册自己，并保持心跳。通过控制连接两端会互相发送一些控制信息，比如说开始新的代理、关闭连接、认证等等。

tunnel 维护逻辑上的端口映射，分为两种：tcp 和 http/https。一个 tcp
例子是：`服务端端口--tunnelAddr<--客户端-->内网目的端口`，http 例子：`服务端http端口（一般是80）--tunnelAddr<--客户端-->内网http服务`。tunnel 记录了必要的信息，保证你从公网访问这个`服务端端口`/`服务端http端口`的时候，ngrokd 能够找到对应的客户端和内网真正的被代理端口。（这里的箭头表明实际连接发起的方向，可以看到所有的连接，不管对内还是对外，都是客户端发起的）

ngrokd 启动的时候，会暴露三个端口，一个（httpAddr）用来监听 http 连接，一个（httspAddr）监听 https 连接，最后一个（tunnelAddr）用来监听两类连接：控制连接和代理连接。

我们分三个阶段来分析 ngrokd 做的工作：

1. 注册阶段
2. 建立代理连接阶段
2. 转发阶段

### 注册阶段

在这个`tunnelListener()`函数里，其实根据控制信息的不同做了分流，分别是`注册阶段`（`NewControl()`）和`建立代理连接阶段`（`NewProxy()`）的入口：

```go
func tunnelListener(addr string, tlsConfig *tls.Config) {
	// 这里监听 tunnelAddr，进来的连接会被打上 tun 的标记，然后放到 listener.Conns 的 channel 里
	listener, err := conn.Listen(addr, "tun", tlsConfig)
	if err != nil {
		panic(err)
	}
	...
	// 而在这里则从上述的 listener.Conns 里取出连接，针对每个连接起一个 goroutine 并发地处理
	for c := range listener.Conns {
		go func(tunnelConn conn.Conn) {
			...
			// 从连接里读取控制信息
			var rawMsg msg.Message
			if rawMsg, err = msg.ReadMsg(tunnelConn); err != nil {
				tunnelConn.Warn("Failed to read message: %v", err)
				tunnelConn.Close()
				return
			}
			...
			// 根据不同的控制信息做不同的操作
			switch m := rawMsg.(type) {
			// 注册一个新的 control（进入注册阶段）
			case *msg.Auth:
				NewControl(tunnelConn, m)
			// 请求建立新的代理连接（进入建立代理连接阶段），后面再解释
			case *msg.RegProxy:
				NewProxy(tunnelConn, m)

			default:
				tunnelConn.Close()
			}
		}(c)
	}
}
```

#### NewContorl() 做了什么

`NewContorl(ctlConn conn.Conn, authMsg *msg.Auth)`做了这么一些事情：

1. 认证
2. 建立`control`实例`c`，上面的参数`ctlConn `会被作为`c`的成员`c.conn`，`control`实例注册到`controlRegistry`
3. 启动发送消息的 goroutine，用来把从`c.out`读到的消息通过`c.conn`发给客户端

	```go
	go c.writer()
	```
	
4. 要求客户端发起代理连接，将控制消息写到`c.out`里，这时候`c.writer()`就会异步地读取`c.out`里的信息
	
	```go
	c.out <- &msg.ReqProxy{}
	```
	
5. 启动三个 goroutine：`c.reader()`负责从控制连接里读信息并写到`c.in`；`c.manager()`负责从`c.in`里读消息并做对应的操作；`c.stopper()`等待停止的信号，负责回收所有资源，包括把`control`实例从`conrtorl`池移除：`controlRegistry.Del(c.id)`等


	```go
go c.manager()
go c.reader()
go c.stopper()	
	```

#### goroutine 和 chan 的配合

这里的 goroutine 和 chan 的用法很经典。`control`实例里有两个`chan`，分别是`in`和`out`，用来达成不同 goroutine 之间的通信。

比如上面提到的“要求客户端发起代理连接”的操作，消息的传递路径是这样的：

在`NewContorl()`goroutine 内，`msg.ReqProxy{}`被塞到`c.out`这个 chan 里：


```go
	c.out <- &msg.ReqProxy{}
```

 在`c.writer()`goroutine 内，不断从`c.out`读，然后把读到的信息`m`写到 `c.conn`（也就是该`control`对应的控制连接）里：

```go
	for m := range c.out {
		c.conn.SetWriteDeadline(time.Now().Add(controlWriteTimeout))
		if err := msg.WriteMsg(c.conn, m); err != nil {
			panic(err)
		}
	}
```
	
而读取消息的路径是`c.conn-->c.read()-->c.in-->c.manager()`。各个 goroutine 都是并发、异步、解耦的，中间通过 channel 串联起来，十分优雅。在各个 chan 没有消息的时候，range 操作是阻塞着的，但因为 goroutine 是异步的，所以不会影响到其他的 goroutine，go 的 runtime 会帮你做好各个执行流的调度。
 
还值得一提的是它的停止机制。`c.stopper()`利用了 chan 的一个特性：一旦 chan 被关闭，range chan 的操作就会退出。如果我们把每个 goroutine “绑定”的 chan 都关闭了，实际上就解除了`range channel`的阻塞和循环状态，相当于关闭了对应的 goroutine。

```go
// range c.out 的三种状态
for m := range c.out{			// 1. c.out 为空：阻塞
	...				// 2. 从 c.out 读到 m：执行大括号里的逻辑
}					
// 其他代码			
	...				// 3. c.out 被关闭，继续执行下面的代码，直到该函数结束
```
 

所以`c.stopper()`一旦接受到 stop 的指令，就会把所有相关的 `chan`（`c.in``c.out`)关闭，则`c.read()``c.manager()``c.writer()`等`goroutine`也就都执行完毕了，从而达到回收`chan`和`goroutine`资源的目的。


#### c.manager() 做了什么

两件事：

1. 和客户端维持心跳
2. 注册 tunnel

```go
func (c *Control) manager() {
	...
	// 实例化一个计时器，每10秒发送一次消息到 reap.C
	reap := time.NewTicker(connReapInterval)
	defer reap.Stop()

	for {
		select {
		// 每10秒 reap.C 就会有内容到达，这里检查客户端发送过来的心跳包，如果大于30秒，就启动停止流程
		case <-reap.C:
			if time.Since(c.lastPing) > pingTimeoutInterval {
				c.conn.Info("Lost heartbeat")
				c.shutdown.Begin()
			}
		// 从 c.in 读取消息
		case mRaw, ok := <-c.in:
			// c.in 若被关闭，ok 的值是 false，直接结束该函数（gorotine）
			if !ok {
				return
			}
			// 根据控制消息的类型，作对应操作
			switch m := mRaw.(type) {
			// 注册 tunnel
			case *msg.ReqTunnel:
				c.registerTunnel(m)
			// 发送心跳包（报告当前时间）
			case *msg.Ping:
				c.lastPing = time.Now()
				c.out <- &msg.Pong{}
			}
		}
	}
}

```

go 标准库里的计时器也是很典型的 channel 的应用。

至此，注册阶段就完毕了。服务端通过客户端的主动连接，知道了客户端的存在，为它注册了一系列资源，向客户端请求了一条代理连接，获知了客户端想要代理的服务信息（tunnel），并通过心跳包保持了联络。

### 建立代理连接阶段

### 转发阶段

## 客户端代码

## 总结

### interface
### goroutine & channel
### select-case & for-range
### reflect


[^1]: ngrok 和 frp 这一类穿透，有两个缺点：1. 一直需要中间服务器；2. 转发很耗费流量。实现内网穿透还可以有其他方式：P2P、探测端口等方法，也有其利弊，本文就暂不讨论了。
