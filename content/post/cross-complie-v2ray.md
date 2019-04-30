---
title: "交叉编译 V2Ray"
date: 2017-12-29T17:17:27+08:00
draft: false
description: "一次交叉编译的踩坑过程"
lastmod: 2018-01-01
keywords: [golang]
tags: [交叉编译,golang,v2ray]
categories: [记录]
---

# 问题和背景
朋友想在路由器里跑 V2Ray，但官方 release 版本不能用，拜托我重新编译一份可执行文件。该路由器没有 FPU（Float Point Unit，浮点运算单元，专用于浮点运算的处理器)，官方 Mips 版本并不支持软解浮点数运算，无法顺利运行。


## 环境
- 目标机器：OpenWRT mipsle（32位机器，小端序）
- 本地机器：CentOS amd64 golang1.9

# 解决过程
参考官方提供的[编译步骤](https://www.v2ray.com/eng/intro/compile.html)：

```
1. （安装 git 和 golang 环境的步骤略去）
2. 下载 V2Ray 源文件：`go get -u v2ray.com/core/...`
3. 下载 V2Ray 扩展包：`go get -u v2ray.com/ext/...`
4. 生成编译脚本：
`go install v2ray.com/ext/tools/build/vbuild`
5. 编译 `V2Ray：$GOPATH/bin/vbuild`
6. V2Ray 程序及配置文件会被放在 `$GOPATH/bin/v2ray-XXX` 文件夹下（XXX 视平台不同而不同）
```

1. 编译 V2Ray 至少要 go1.9 以上的版本
  最新的 v2ray 源码是 go1.9 实现的，如果用 go1.8 进行编译会提示找不到“math/bits”标准库文件
  `unrecognized import path "math/bits" (import path does not begin with hostname)`
  （https://github.com/v2ray/v2ray-core/issues/633）

2. 目标机器没有 FPU，指令集缺乏相关的指令，所以只能用软件模拟浮点数运算。go 的 beta 版本已经修复了这个问题：[runtime: mips32 soft float point support](https://github.com/golang/go/issues/18162)

3. 下载 go1.10beta1
  ```
  $ go get golang.org/x/build/version/go1.10beta1
  $ go1.10beta1 download
  ```

4. 则生成编译脚本的命令为
  ```
  $ env GOARCH=mipsle GOMIPS=softfloat go1.10beta1 install v2ray.com/ext/tools/build/vbuild
  ```
  GOARCH 指定目标机器的指令集，GOMIPS 指定 mipsle 机器处理浮点数的方式（分 softfloat和hardfloat，默认为hardfloat，所以需显示指定）

    go1.10beta1 指明使用 beta 版本进行编译

5. 将 vbuild 传到目标机器，执行：
	
	  ```
	  $ ./vbuild
	  Building V2Ray (custom) for linux mipsle
	  Unable to build V2Ray: exec: "go": executable file not found in $PATH

	  ```

	  这里我理解错误，以为 vbuild 已经是可执行文件，不需要依赖 go 环境。实际上这只是编译脚本，仍然依赖于 go 环境和 v2ray 的依赖包，而目标机器没有 go 环境和 v2ray 的依赖库（install的过程会把需要的依赖库安装到同级别目录下的 pkg 下）。所以按照官方的编译方式达不到交叉编译的目的。
	
	  如果要用 vbuild 达到交叉编译的目的，需要把 GOARCH=mipsle GOMIPS=softfloat 环境变量传给 vbuild，并将所有外部命令中的“go”修改为“go1.10beta1”。
	
	  或者自己手动编译。我选择手动编译，比较灵活可控。

	  查看 vbuild 源码，有类似语句：
	
	    ...
	    // 读取依赖库路径
	      targetFile := getTargetFile("v2ray", v2rayOS)
	      targetFileFull := filepath.Join(targetDir, targetFile)
	      	if err := build.BuildV2RayCore(targetFileFull, v2rayOS, v2rayArch, false); err != nil {
	      		fmt.Println("Unable to build V2Ray: " + err.Error())
	      		return
	      	}
	    ...
	
	    ...
	    // 执行外部命令
	    cmd := exec.Command("go", args...)
	    ...


6. 手动编译 v2ray 主程序和 v2ctl。主程序需通过 v2ctl 读取配置文件。

    ```
    //编译 V2Ray 主程序

    $ cd $GOPATH/src/v2ray/core/main
    $ env GOARCH=mipsle GOMIPS=softfloat go1.10beta1 build -ldflags '-w -s' -o v2ray

    // 编译 v2ctl

    $ cd $GOPATH/src/v2ray.com/ext/tools/control/main
    $ env GOARCH=mipsle GOMIPS=softfloat go1.10beta1 build -ldflags '-w -s' -o v2ctl

    // 编译出来的二进制文件可用 upx 进行压缩

    $ upx v2ray
    $ upx v2ctl
    ```

7. 将 v2ray 和 v2ctl 放到目标机器可正常运行。问题解决！

# 其他问题

1. 输错编译参数 GOARCH=mips，在目标机器运行报错：

    ```
    $ ./vbuild
    ./vbuild: line 1: syntax error: unterminated quoted string
    ```

    实际上 mips 为大端序，mipsle 是小端序，两者不等同。

2. 编译出来的可执行文件有点大，动辄10几M，不利于网络传输，而在路由器这种外存空间有限的硬件上，文件也当然越小越好。[upx](https://github.com/upx/upx)是一个 C++ 写的开源加壳压缩工具，能满足这个需求。

### upx 原理
通过 upx 压缩过的程序和程序库完全没有功能损失和压缩之前一样可正常地运行。upx 利用特殊的算法压缩了二进制，并在文件加了解压缩的指令，cpu 读到这些指令可以自己解压缩。cpu 在执行加壳过的二进制时，相当于先执行了外壳，再通过外壳在内存中把原来的程序解开并执行。

upx 能实现两个需求，一个是压缩，另一个是加密程序，防止程序被别人静态分析。很方便。

### 下载安装 upx
1. 下载 upx：

    ```
    wget -c https://github.com/upx/upx/releases/download/v3.94/upx-3.94-amd64_linux.tar.xz
    ```

2. 解压缩：

    ```
    $ tar -Jxf upx-3.94-amd64_linux.tar.xz
    ```

3. 把upx放到环境变量能访问到的地方：

    ```
    $ cd upx-3.94-amd64_linux && mv upx $GOPATH/bin
    ```

### 压缩前后对比

1. 普通编译，大小为14M：

    ```
    $ go1.10beta1 build

    $ ls -lh
    -rwxr-xr-x. 1 root root 14M Dec 29 14:38 main
    ```

2. go build 时用 ldflags 设置变量的值，-s 去掉符号信息， -w 去掉 DWARF 调试信息（去掉后无法是用 GDB 进行调试），大小为11M：

    ```
    $ go1.10beta1 build -ldflags '-w -s'

    $ ls -lh
    -rwxr-xr-x. 1 root root 11M Dec 29 14:38 main
    ```

3. 用 upx 加壳压缩，大小为3.7M

    ```
    $ upx main
    Ultimate Packer for eXecutables
       Copyright (C) 1996 - 2017
    UPX 3.94        Markus Oberhumer, Laszlo Molnar & John Reiser   May 12th 2017

    File size         Ratio      Format      Name
    --------------------   ------   -----------   -----------
    11110408 ->   3861696   34.76%   linux/amd64   main

    Packed 1 file.

    $ ls -lh
    -rwxr-xr-x. 1 root root 3.7M Dec 29 14:38 main

    ```

可以看到压缩比能达到（3.7M/14M）26%，很可观了，传输和存储该文件会方便许多，且压缩后的二进制文件可正常执行。

# 总结
编译型的语言优点是执行效率高，毕竟翻译成机器码，免去了很多中间环节，但缺点就是要针对跨平台进行优化。不同平台操作系统、指令集架构、硬件都不一样，要求程序员对体系结构有所了解。特别是 go 程序的编写，了解不同平台和底层模型有助于写出高性能的程序。另网络应用经常有跨平台的使用场景，如路由器、物联网设备，这些设备跟普通 pc 机和服务器的硬件和体系结构会有差别，在用高层次语言写网络应用也要有这个意识。

# 参考链接
1. [解决GO语言编译程序无法在openwrt上运行的问题](https://stray.love/wen-ti-jie-jue-fang-an/jie-jue-goyu-yan-bian-yi-cheng-xu-wu-fa-zai-openwrtshang-yun-xing-de-wen-ti)
2. [runtime: mips32 soft float point support](https://github.com/golang/go/issues/18162)
3. [go-mips32 交叉编译go程序 编译kcptun例子](https://github.com/xtaci/kcptun/issues/79)
