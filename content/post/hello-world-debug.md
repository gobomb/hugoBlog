---
title: "Hello World 也会有 bug？"
date: 2023-05-29T23:03:01+08:00
draft: false
---

# 引言

前阵子一个朋友发我一篇[文章](https://blog.sunfishcode.online/bugs-in-hello-world/)，大意是说很多语言的经典程序——打印“hello world”——也是会出bug的。

文中举了一个C的例子：

```C
/* Hello World in C, Ansi-style */

#include <stdio.h>
#include <stdlib.h>

int main(void)
{
  puts("Hello World!");
  return EXIT_SUCCESS;
}
```

编译运行后，却不会报错：

```shell
$ gcc hello.c -o hello
$ ./hello > /dev/full
$ echo $?
0
```

通过 strace 追踪系统调用，是能看到 write 返回错误的：

```shell
$ strace -etrace=write ./hello > /dev/full
write(1, "Hello World!\n", 13)          = -1 ENOSPC (No space left on device)
+++ exited with 0 +++
```

但是上面的 C 程序并没有把错误返回出来。

作者罗列了几个主流的语言，打印函数没有报错的：C、C++、Python 2、Java 等，有报错的 Rust、 Python 3、Bash、C# 等。

没有列出 Go。于是我有点好奇，随手写了一个 Hello World (go1.17.2 linux/amd64)：

```go
package main

import "fmt"

func main() {
	fmt.Println("Hello world!")
}
```

试了下，发现也没有报错：

```shell
$ go build -o hello main.go
$ ./hello > /dev/full
$ echo $?
0
```

# rust 的表现

我又用 rust 试了下：

```rust
fn main(){
    println!("Hello World!");
}
```

确实如作者所言，会把错误抛出来，而且错误还很详细:

```shell
$ rustc -o hello main.rs
$ ./hello  >/dev/full
thread 'main' panicked at 'failed printing to stdout: No space left on device (os error 28)', library/std/src/io/stdio.rs:1008:9
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
$ echo $?
101
```

添加环境变量还可看完整的 backtrace：

```shell
$ RUST_BACKTRACE=1 ./hello  >/dev/full
thread 'main' panicked at 'failed printing to stdout: No space left on device (os error 28)', library/std/src/io/stdio.rs:1008:9
stack backtrace:
   0: rust_begin_unwind
             at ./rustc/84c898d65adf2f39a5a98507f1fe0ce10a2b8dbc/library/std/src/panicking.rs:579:5
   1: core::panicking::panic_fmt
             at ./rustc/84c898d65adf2f39a5a98507f1fe0ce10a2b8dbc/library/core/src/panicking.rs:64:14
   2: std::io::stdio::print_to
             at ./rustc/84c898d65adf2f39a5a98507f1fe0ce10a2b8dbc/library/std/src/io/stdio.rs:1008:9
   3: std::io::stdio::_print
             at ./rustc/84c898d65adf2f39a5a98507f1fe0ce10a2b8dbc/library/std/src/io/stdio.rs:1074:5
   4: main::main
   5: core::ops::function::FnOnce::call_once
note: Some details are omitted, run with `RUST_BACKTRACE=full` for a verbose backtrace.
```

还能进一步看详细的 backtrace。突然觉得好贴心。


# Go 的 bug

到这里，我就有点兴奋，该不会Go的实现真的有bug吧，赶紧看看源码。才点开 fmt.Println 的函数签名，我就发现了“问题”：

```go
// Println formats using the default formats for its operands and writes to standard output.
// Spaces are always added between operands and a newline is appended.
// It returns the number of bytes written and any write error encountered.
func Println(a ...interface{}) (n int, err error) {
	return Fprintln(os.Stdout, a...)
}
```

Println 是有返回值的，返回写入的字节数和可能的写错误。

所以不是程序有bug，而是使用方式不对。

重新实现如下：

```go
package main

import "fmt"

func main() {
	n, err := fmt.Println("Hello world!")
	if err != nil {
		println("got err: ", err.Error())
	}

	println("written bytes: ", n)

}
```

编译运行：

```shell
$ go build -o hello2 main2.go
$ ./hello2 > /dev/full
got err:  write /dev/stdout: no space left on device
written bytes:  0
```

符合预期，错误是被处理的。

所以，并不是说语言本身实现有bug，而是使用语言写代码的时候，考虑得不周全。

# C 的 bug

那，回到最开头的C的例子，是不是也是使用者的问题呢？

puts 是不是也有返回值呢?

```c
int puts(const char *str)
```

跟 go 有点像，返回了一个int类型，指示写了多少字节，那错误在哪里呢？

错误可以通过`#include <errno.h>`，获取到全局变量`errno`

于是程序可以改写成：


```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>

int main(void)
{
  int n;
  n = puts("Hello World!");
  if(errno!=0){
    // 为了不干扰标准输出，把错误信息打印到标准错误了
    fprintf(stderr,"puts got err %d\n",n,errno);
    return errno;
  }

  fprintf(stderr,"puts %d bytes\n",n );
}
```

编译运行：

```shell
$ gcc hello2.c -o hello2
$ ./hello2 >>/dev/full
puts 13 bytes
$ echo $?
0
```

已经尝试获取了错误，却仍然没有得到错误？问题在哪里呢？

这里得考虑实现了：**puts这个函数是带缓冲的。** 

翻阅《UNIX 环境高级编程》5.4 章：

    标准I/O库提供缓冲的目的是尽可能减少使用read和write调用的次数。它也对每个I/O流自动地进行缓冲管理，从而避免了应用程序需要考虑这一点所带来的麻烦。
    
    （1）全缓冲。这种情况下，在填满标准I/O缓冲区后才进行实际的I/O操作。对于驻留在磁盘上的文件通常是由标准I/O库实施全缓冲的。在一个流上执行第一次I/O操作时，相关标准I/O函数通常调用malloc获得需使用的缓冲区。
    
    术语冲洗（flush）说明标准I/O缓冲区的写操作。缓冲区可由标准I/O例程自动冲洗（例如当填满一个缓冲区时），或者可以调用函数fflush冲洗一个流。值得引起注意的是在UNIX环境中，flush有两种意思：在标准I/O库方面，flush（冲洗）意味着将缓冲区中的内容写到磁盘上（该缓冲区可能只是局部填写的）。在终端驱动程序方面，flush（刷清）表示丢弃已存储在缓冲区中的数据。


所以puts写到缓冲里，是成功的，所以没有报错。那我们调用 fflush 进行写盘呢？

第三版如下：


```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>

int main(void)
{
  int n;
  n = puts("Hello World!");
  if(errno!=0){
    fprintf(stderr,"puts got err %d\n",n,errno);
    return errno;
  }

  fprintf(stderr,"puts %d bytes\n",n );

  n = fflush(stdout);
  if(errno!=0){
    fprintf(stderr,"fflush got err %d\n",errno);
    return errno;
  }

  fprintf(stderr,"flushed %d bytes\n",n );

  return EXIT_SUCCESS;
}
```

编译运行：

```shell
$ gcc hello3.c -o hello3
$ ./hello3 >>/dev/full
puts 13 bytes
fflush got err 28
$ echo $?
28
```

啊哈！这个错误终于被捕获了，errno.h里显示错误定义如下：

```
#define ENOSPC 28 /* No space left on device */
```

# 总结

所以，即使是打印一个 hello world，这个每个新语言的经典程序，也有可能出 bug。但准确的说不是语言本身的bug，而是语言的假设结合程序员的使用造成的。

在 C 的情况下，如果不是编程老手，熟悉库函数和各种约定（新手一上来哪知道errno是藏在全局变量里的），底层操作系统知识烂熟于心（标准IO、缓冲），都没有意识到错误的发生。即便如此，深入排查和验证问题，还要3个来回。

Go 同理，默认情况下，错误极易被忽略了。我想很多人都不见得会去处理 fmt.Println 返回的错误。但从函数的封装上，是屏蔽了部分底层细节了，多返回值提高了易用性，还保留了C风味。但不去处理错误，也还是调用方的责任。

而 Rust 则提供了更佳严格的错误返回，把问题显示抛了出来，还提供了分级别的调用栈打印，是我意料之外的。这种丰富的错误打印，是能节省使用者不少时间的。

C假设你是老手，Go也假设你是严谨的，Rust则提供了所有的细节。

写出严谨的程序没有那么容易，即使是最简单的打印 hello world。尽量还是选择趁手先进的工具，以及好的排错工具。我们很难面面俱到地考虑到所有异常情况，所以良好的测试，以及完善的报错信息是很有必要的。

# 后话

我搜了下这篇文章，发现了一些有意思的讨论：

如 [reddit](https://www.reddit.com/r/programming/comments/ta2a2z/bugs_in_hello_world/) 上:

> if you don't realize that the buffering is the problem, you may wonder for a while why printf() reports success. Error handling is hard.

还有[ycombinator](https://news.ycombinator.com/item?id=30611367) 也有一长串讨论。

