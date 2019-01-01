---
title: "ngrok 源码解析"
date: 2018-12-17T02:08:25+08:00
draft: false
description: "ngrok 源码阅读；go 语言学习"
lastmod: 2019-01-01
keywords: [golang]
tags: [golang,源码,网络编程,goroutine,channel]
categories: [技术文章]
---

## 背景

[ngrok](https://github.com/inconshreveable/ngrok)是我第一个完整阅读过源码的开源项目。一开始接触这套代码我几乎还是 go 语言零基础，之前只写过一点点 Web 后端 API，后来趁着做毕业设计的机会还跟着源码重新敲了一遍，按照我自己的需要小改了一下。所以我从中收获了不少东西，一直都想写一篇文章总结一下我对这套代码的理解。

ngrok 的目的是将本地的端口反向代理到公网，让你可以通过访问公网某个服务器，经过流量转发，访问到内网的机器。这个事情你可以有不同的叫法：反向代理、端口转发（映射）、内网穿透[^1]……原理其实不难，解决的需求也简单。

我们个人的设备一般都在 NAT （公司、学校内网，运营商也会喜欢做 NAT）后面，不能被公网设备直接访问到。内网机器可以主动向公网发起连接，但公网却不能穿越 NAT 主动访问到内网机器。ngrok 就适合用来穿越 NAT 来临时暴露内网服务。在技术人员常聚集的社区 V2EX，经常能看到问怎么做内网穿透的月经贴。可见这个需求十分常见。

内网穿透的工具，现在大家用的比较多的是 [frp](https://github.com/fatedier/frp)了。frp 是中国人开发的，增加了很多新的功能，使用体验也比 ngrok 好很多，社区比较活跃。ngrok 虽然出现得比较早，但 2.0 转闭源， 1.0 不再维护了，用得人也少了。但这不妨碍我们扒源码学习。

## 项目结构

先来看一下 ngrok 整个项目的结构（忽略掉了一些不必要的文件）：

```
.
├── ...
├── assets							// 存放 web 静态文件和 tls 文件
│   ├── ...
└── src
    └── ngrok
        ├── cache					// 缓存
        │   └── lru.go
        ├── client
        │   ├── cli.go				// 命令行参数定义
        │   ├── config.go			// 配置文件读取
        │   ├── controller.go		// MVC 控制器
        │   ├── main.go				// 程序入口
        │   ├── metrics.go			// 性能数据收集
        │   ├── model.go			// ClientModel，主要的转发逻辑
        │   ├── mvc					// MVC 接口
        │   │   ├── ...
        │   ├── tls.go				// tls 证书加载
        │   └── views				// view 层包括 Web 和终端 
        │   │   ├── ...
        |   |──...
        ├── conn						// tcp 连接相关的操作：标记连接的类型（http/tcp），发起监听（Listen）、发起主动连接（Dial），以及关键的交换两个连接的数据（Join）
        │   ├── conn.go
        │   └── tee.go
        ├── log						// 日志
        │   └── logger.go
        ├── main						// 程序入口
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
        │   ├── ...
        │   └── shutdown.go		// 通过锁、channle、defer实现的关闭机制
        └── version
            └── version.go			// 输出版本号

```

## 服务端代码

我们从 main 函数开始来过一下服务端 ngrokd 的关键代码（为了简洁，以下代码大都忽略掉了错误处理和资源清理的语句；正文引用到的函数签名则省略了参数）：

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

在这里一个`control对应一个 ngrok 客户端，每个客户端可能处于不同的 NAT 之后。客户端会主动连接`tunnelAddr`端口，向服务端建立`控制连接`，注册自己，并保持心跳。通过控制连接两端会互相发送一些`控制信息`，比如说开始新的代理、关闭连接、认证等等。

`tunnel`维护逻辑上的端口映射，分为两种：TCP 和 HTTP/HTTPS。一个 TCP
映射的路径是：`服务端端口--tunnelAddr<--客户端-->内网目的端口`，HTTP ：`服务端http端口（一般是80）--tunnelAddr<--客户端-->内网http服务`。`tunnel`记录了必要的信息，保证你从公网访问这个`服务端端口`/`服务端http端口`的时候，ngrokd 能够找到对应的客户端和内网里真正的被代理端口。（这里的箭头表明实际连接发起的方向，可以看到所有的连接，不管对内还是对外，都是客户端发起的）

ngrokd 启动的时候，会暴露三个主要端口，一个（`httpAddr`）用来监听 HTTP 连接，一个（`httspAddr`）监听 HTTPS 连接，最后一个（`tunnelAddr`）用来监听两类连接：`控制连接`和`代理连接`。后面当`tunnel`注册的时候，还会随机或由客户端指定一些端口，用以给提供公网侧的 TCP 代理。

我们分三个阶段来分析 ngrokd 做的工作：

1. 注册阶段
2. 建立代理连接阶段
2. 转发阶段

### 注册阶段

在这个`tunnelListener()`函数里，其实根据`控制信息`的不同做了分流，分别是`注册阶段`（`NewControl()`）和`建立代理连接阶段`（`NewProxy()`）的入口：

```go
func tunnelListener(addr string, tlsConfig *tls.Config) {
	// 这里监听 tunnelAddr，进来的连接会被打上 tun 的标记，然后放到 listener.Conns 的 channel 里
	listener, err := conn.Listen(addr, "tun", tlsConfig)
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

### - NewContorl() 做了什么

`NewContorl(ctlConn conn.Conn, authMsg *msg.Auth)`做了这么一些事情：

1. 认证
2. 建立`control`实例`c`，上面的参数`ctlConn `会被作为`c`的属性`c.conn`，而`control`实例`c`会被注册到`controlRegistry`
3. 启动发送消息的 goroutine，用来把从`c.out`读到的消息通过`c.conn`发给客户端: 

	```
	go c.writer()
	```

4. 要求客户端发起代理连接，将控制消息写到`c.out`里，这时候`c.writer()`就会异步地读取`c.out`里的信息

	```
	c.out <- &msg.ReqProxy{}
	```
	
5. 启动三个 goroutine：`c.reader()`负责从控制连接里读信息并写到`c.in`；`c.manager()`负责从`c.in`里读消息并做对应的操作；`c.stopper()`等待停止的信号，负责回收所有资源，包括把`control`实例从`control`池移除：`controlRegistry.Del(c.id)`等


	```
go c.manager()
go c.reader()
go c.stopper()	
	```

### - goroutine 和 chan 的配合

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
		...
	}
```
	
而读取消息的路径是`c.conn-->c.read()-->c.in-->c.manager()`。各个 goroutine 都是并发、异步、解耦的，中间通过 channel 串联起来，十分优雅。在各个 chan 没有消息的时候，`range`操作是阻塞着的，但因为 goroutine 是异步的，所以不会影响到其他的 goroutine，go 的 runtime 会帮你做好各个执行流的调度。
 
还值得一提的是它的停止机制。`c.stopper()`利用了 chan 的一个特性：一旦 chan 被关闭，`range chan`的操作就会退出。如果我们把每个 goroutine “绑定”的 chan 都关闭了，实际上就解除了`range chan`的阻塞和循环状态，相当于关闭了对应的 goroutine。

```go
// range c.out 的三种状态
for m := range c.out{			// 1. c.out 为空：阻塞
	...				// 2. 从 c.out 读到 m：执行大括号里的逻辑
}					
// 其他代码			
	...				// 3. c.out 被关闭，继续执行下面的代码，直到该函数结束
```
 

所以`c.stopper()`一旦接受到 stop 的指令，就会把所有相关的 `chan`（`c.in``c.out`)关闭，则`c.read()``c.manager()``c.writer()`等`goroutine`也就都执行完毕了，从而达到回收`chan`和`goroutine`资源的目的。


### - c.manager() 做了什么

两件事：

1. 和客户端维持心跳
2. 注册`tunnel`

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
			// 收到来自客户端的 tunnel 信息，注册 tunnel
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

### - registerTunnel() 做了什么

在`registerTunnel()`里，会检查`tunnel`的类型，做出不同的处理：

1. 如果是 TCP 类型，则监听客户端指定的`公网侧端口`；如果指定端口号为0，会随机分配一个。每个`TCP tunnel`都会分配一个唯一的端口，也就是说我们会通过端口号来区分 TCP 类型的`tunnel`。
2. 如果是 HTTP/HTTPS 类型，则是共用端口（一般是80和443）。通过不同的 URL 来区分`tunnel`，URL 可能是自己指定的域名、当前服务器域名的指定子域名，或者当前服务器域名的随机子域名。

处理完`tunnel`，就将`tunnel`都注册到`tunnelRegistry`中。并向客户端报告注册成功。

至此，注册阶段就完毕了。此时服务端的状态是：
1. 通过客户端的主动连接，知道了客户端的存在，为它注册了一系列资源；
2. 向客户端请求了一条代理连接；
3. 获知了客户端想要代理的服务信息（`tunnel`）；
4. 通过心跳包与客户端保持了联络，保证`控制连接`不断。

### 建立代理连接阶段

从上述`注册阶段`提到`tunnelListener()`会`控制连接`里的消息对连接进行分流，当从控制连接收到`*msg.RegProxy`时，将进入`NewProxy(tunnelConn, m)`方法注册一条新的`代理连接`,这条连接会被存进对应的`control`实例所拥有的一个 channel 里：`c.proxies <- conn`。当需要进行转发和代理的时候，这个 channel 就会被消费。

### 转发阶段

真正的转发过程就比较简单了。服务端从`公网侧端口`得到用户主动发起的公网连接（`pubConn`），会调用 tunnel 的`HandlePublicConnection`方法，从 control 的`proxies` channel 里得到一条`代理连接`（如果 channel 为空，则再走一次`建立代理连接阶段`，让客户端再次发起一个代理连接），接着通过代理连接通知客户端：准备开始转发数据，然后用一个`conn.Join(publicConn, proxyConn)`方法，交换公网连接和代理连接的数据。这样，用户发送的数据就会被转发给客户端，客户端转发给真正的内网服务；从客户端发送过来的数据，也反过来转发给用户。

`conn.Join()`的代码如下，客户端的转发也调用了此方法：

```
func Join(c Conn, c2 Conn) (int64, int64) {
	var wait sync.WaitGroup

	pipe := func(to Conn, from Conn, bytesCopied *int64) {
		defer to.Close()
		defer from.Close()
		defer wait.Done()

		var err error
		*bytesCopied, err = io.Copy(to, from)
		if err != nil {
			from.Warn("Copied %d bytes to %s before failing with error %v", *bytesCopied, to.Id(), err)
		} else {
			from.Debug("Copied %d bytes to %s", *bytesCopied, to.Id())
		}
	}

	wait.Add(2)
	var fromBytes, toBytes int64
	go pipe(c, c2, &fromBytes)
	go pipe(c2, c, &toBytes)
	c.Info("Joined with connection %s", c2.Id())
	wait.Wait()
	return fromBytes, toBytes
}
```

可以看到，最终是在两个 goroutine 里调用官方库函数`io.Copy`来异步地复制数据。


## 客户端代码

客户端的代码就比较简单一点。客户端采用 MVC 的架构，因为客户端除了与服务端、内网服务进行交互，还有与用户交互的界面。这里主要是 terminal 和 web。与用户交互的部分我不想详细介绍，主要讲一讲与服务端相关的部分。

客户端也是创建一个`ClientModel`对象实例来和服务端进行交互，在`ClientModel`的`control()`方法中，客户端向服务端的`tunnelAddr`端口建立连接，发送认证消息注册自己，再发送用户指定的`tunnel`信息，同时创建一个 goroutine 用来维持心跳，保持此条控制连接不断开。这里对应服务端的`注册阶段`。

如果服务端要求建立代理，客户端就向`tunnelAddr`端口新建一条代理连接（`proxyConn`）。并在此代理连接中等待服务端通知代理开始的信号，一旦接受到信号，就向对应的内网服务建立连接（`localConn`），作出请求。和服务端`转发阶段`类似，这里会调用`conn.Join(localConn, remoteConn)`交换两条连接的数据。用户向服务端的请求，就在这里被转发到内网服务，内网服务的响应，也在这里原路返回。


```go
func (c *ClientModel) proxy() {
	...
	// 建立代理连接
	if c.proxyUrl == "" {
		remoteConn, err = conn.Dial(c.serverAddr, "pxy", c.tlsConfig)
	} else {
		remoteConn, err = conn.DialHttpProxy(c.proxyUrl, c.serverAddr, "pxy", c.tlsConfig)
	}
	...

	// 向服务端注册代理连接
	err = msg.WriteMsg(remoteConn, &msg.RegProxy{ClientId: c.id})
	...
	
	// 从代理连接中收到服务端开始代理的通知
	var startPxy msg.StartProxy
	if err = msg.ReadMsgInto(remoteConn, &startPxy); err != nil {
		remoteConn.Error("Server failed to write StartProxy: %v", err)
		return
	}

	// 通过 URL 找到对应的 tunnel，以及相应的内网服务
	tunnel, ok := c.tunnels[startPxy.Url]

	// 向内网服务发起连接
	start := time.Now()
	localConn, err := conn.Dial(tunnel.LocalAddr, "prv", nil)
	...
	
	m.connTimer.Time(func() {
		...
		// 内网连接和代理连接交换数据
		bytesIn, bytesOut := conn.Join(localConn, remoteConn)
		...
	})
}
```

## 总结

首先必须一提的就是 goroutine 和 channel，如上文提到的通过 channel 来传递消息和停止 goroutine，都是比较巧妙的用法，

在 ngrok 中，另一个被大量用到的用法就是`type-switch`了。往往我们从 chan 里拿到的数据结构，是一个空接口`interface{}`，我们不确定它的类型，需要通过`类型断言`来得到它的类型。在网络编程中，经常会用到这个。

如果对网络编程有兴趣，或者对 go 有兴趣，不妨读一读这套代码。作为一个用于入门的小项目，难度不会过高，又有比较符合 go 风格的代码以快速学习，同时也可以熟悉一下 TCP 编程。用 go 进行网络编程有两个好处，一个是标准库一般足够用，网络相关的开发，使用官方标准库就足以应付大部分场景，另一个是并发的学习曲线低。

[^1]: ngrok 和 frp 这一类穿透，有两个缺点：1. 一直需要中间服务器；2. 转发很耗费流量。实现内网穿透还可以有其他方式：P2P、探测端口等方法，也有其利弊，本文就暂不讨论了。
