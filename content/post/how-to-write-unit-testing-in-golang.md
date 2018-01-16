---
title: "Golang 自带的单元测试"
date: 2017-11-06T16:52:19+08:00
draft: false
description: "了解一下 Goalng 的测试"
lastmod: 2018-01-01
keywords: [golang]
tags: [golang,测试]
categories: [记录]
---


## 为什么要写单元测试


以前写程序的时候，一般不写测试，阅读开源代码遇到测试也都是跳过不读。调试的时候一半都是手动输入测试数据，在代码里打印 log 信息。实际上重复性的工作很多，这一部分是可以用单元测试来做的。

另外，当项目比较大的时候，一般都是把项目分割成几个模块来写的。可以分别保证各个模块的正确性，最后再把各个项目组合起来。这时候也需要单元测试，增强可维护性。

人的记忆力和思考能力毕竟是有限的，并不一定能马上想到边界条件和 bug 可能出现的地方，当代码发生更改，边界条件可能就改变了，程序可能会跑不通，这时跑一下测试代码，可以更快发现问题。

测试保证程序是可运行的，运行结果是正确的，使问题及早暴露，便于问题的定位解决。而性能测试则关注程序在**高并发**的情况下的稳定性。

单元测试也可以方便读代码的人读懂，通过测试代码可以更快了解这个项目到底是干嘛的、该如何用。


## 怎么写单元测试

### 单元测试

* go语言自己有一个轻量级的测试框架 `testing`和命令`go test`,可用来进行单元测试和性能测试。

* 测试文件用 `xxx_test.go`命名，测试函数命名为`TestXxx`或`Test_Xxx`

* 在终端中输入 `go test`，将对当前目录下的所有`xxx_test.go`文件进行编译并自动运行测试。


* 测试某个文件，要带上被测试的原文件

&ensp;&emsp;&emsp;`go test xxx.go xxx_test.go
`


* 测试某个方法:`go test -run='Test_Xxx'`

* `go  test -v` 则输出通过的测试函数信息

如对以下代码进行测试：
```go
package test

func Fibonacci(n int) int{
	if n==1{
		return 1
	}else if n==0{
		return 1
	}
	return Fibonacci(n-1)+Fibonacci(n-2)
}

```


测试代码为：

```go
package test

import "testing"

func TestFibonacci5(t *testing.T) {
	e:=Fibonacci(5)
	if e!= 8{
		t.Fail()
	}else{
		t.Log("ok")
	}
}

func TestFibonacci8(t *testing.T) {
	e:=Fibonacci(8)
	if e!= 34{
		t.Fail()
	}else{
		t.Log("ok")
	}
}

```



### 性能(压力)测试：

* 性能测试的函数命名为`BenchmarkXxx`

* 函数格式为`func BenchmarkXXX(b *testing.B) { ... }`

* `go test`默认不会执行压力测试的函数，要执行压力测试需要带上参数`-bench`指定测试函数，例如`go test -bench=.*`表示测试全部的压力测试函数。

* 文件名也必须以`_test.go`结尾

一个示例压测代码：
```go
package test

import (
	"testing"
)

func Benchmark_Fibonacci(b *testing.B) {
	for i := 0; i < b.N; i++ { //use b.N for looping
		Fibonacci( 20)

	}
	//b.Log(b.N)

}

func Benchmark_TimeConsumingFunction(b *testing.B) {
	b.StopTimer() //调用该函数停止压力测试的时间计数

	//做一些初始化的工作,例如读取文件数据,数据库连接之类的,
	//这样这些时间不影响我们测试函数本身的性能
	num:=35

	b.StartTimer() //重新开始时间
	for i := 0; i < b.N; i++ {
		Fibonacci( num)
	}
}
```


```
go test -test.bench="Benchmark_Fibonacci"

Benchmark_Fibonacci-4              30000             51647 ns/op
PASS
ok      projects/test   2.073s
```

以上输出说明`Benchmark_Fibonacci`执行了30000次，每次的执行平均时间是51647纳秒。

### 参考文章
* https://github.com/astaxie/build-web-application-with-golang/blob/master/zh/11.3.md<br>
* http://www.cnblogs.com/yjf512/archive/2013/01/22/2870927.html<br>
