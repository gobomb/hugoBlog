---
title: "编程语言的求值策略"
date: 2018-01-25T17:09:03+08:00
draft: false
description: "按值传递 / 按引用传递 / 按共享对象传递的区别和总结"
keywords: [编程语言,求值策略]
tags: [编程语言,求值策略,golang]
categories: [技术文章]
---

在面试的时候遇到一个问题：“golang 的传参是按值传递还是按引用传递？”我第一反应是 go 在很多场景下传参和赋值都会发生内存的复制，同时记得 go 里也有引用类型（map、slice、channel），就贸然给出“类似 slice 的引用类型是按引用传递的，其他是按值传递”的错误回答（正确答案是“golang 都是按值传递”）。

这其实是与[求值策略(Evaluation strategy)](https://en.wikipedia.org/wiki/Evaluation_strategy)相关的概念。在传递参数的时候，编译器是怎么进行求值的，是否会发生内存的复制，不同的语言有自己的规定。不了解所使用的编程语言的规定，就很容易出错，也很容易写出低效率的代码。


## 定义

这些概念有些抽象，从字面理解，很容易产生歧义。先尽量跳出某一种编程语言的习惯，做出一些定义，再来讨论具体语言的特定做法。了解通用的定义，对于不同的语言的规定以及为何这么规定会更加清晰。

`求值策略`(Evaluation strategy)指确定编程语言中表达式的求值的一组（通常确定性的）规则。描述的是求值和传值的方式，关注的点在于，表达式在调用函数的过程中，**求值的时机**、**值的形式的选取**等问题。

1. 按值传递（Pass by value）：函数的形参是被调用时所传**实参的副本**。修改形参的值并不会影响实参。（发生了值的复制）
2. 按引用传递（Pass by reference）：传递给函数的是它的**实参的隐式引用**（别名）而不是实参的拷贝。修改形参会改变实参。（发生了引用的复制）
3. 按共享对象传递（Pass by sharing）：传一个共享对象的**引用的副本**。修改**形参的值**会影响实参，修改**形参本身**不会影响实参。（发生了地址/指针的复制）


比如传递一个`a`，设`a`的引用为`rf`，`a`的地址为`ad`：

1. 按值传递：`a`的值复制给`b`，函数拿到的是`b`的值和`b`的引用，和`a`无关。函数通过`b`的引用修改`b`，对调用者不可见。
	
	```
		（主函数）rf of a -> ad of a -> a:100 
										|
										| 复
										↓ 制
		（子函数）rf of b -> ad of b -> b:100 
	```

2. 按引用传递：`a`的值没有发生复制，函数拿到的是`a`的引用`ar`，通过这个引用修改`a`，也对调用者可见。
	
	```
		（主函数）rf of a -> ad of a -> a:100 
	                |		    ^
		 		 复 |		   |
		 		 制 ↓		   |
		（子函数）rf of a ----—--> 	
	```
	
3. 按共享对象传递：重新构造了一个指向`a`的引用`rf2`，将`a`的地址复制给`rf2`，函数拿到的是这个`rf`的副本`rf2`，通过`rf2`修改`a`的值，对调用者可见，但如果修改引用`rf2`本身（使它指向别的地址），是对调用者不可见的，因为改的是副本。
	
	```
		（主函数）rf of a -> ad of a -> a:100 
			     			   |       ^
		           			复 |	      |
		           			制 ↓		  |
		（子函数）rf2 of a -> ad of a -—> 
	```
	
## 例子

### 一个按值传递的例子(go)
---


```go
func call(a A) {
	fmt.Printf("%p\n",&a)	// 0xc42000a0e0
	a.i=7
	fmt.Printf("%p\n",&a) // 0xc42000a0e0
}
	
type A struct{
	i int
	j string
}
	
func main() {
	a := A{
		5,
		"hello",
	}
	fmt.Printf("%p\n",&a)	// 0xc42000a0c0
	call(a)
	fmt.Println(a)			// {5 hello}	
	fmt.Printf("%p\n",&a)	// 0xc42000a0c0
}

`
```
	
可以看到在主函数调用子函数前后，结构体的指针值没有发生变化，且内容不受子函数影响；子函数的形参有了新地址，修改形参只是修改形参地址的内容。说明整个结构体的内容被复制到了新地址，修改新地址的内容与主函数无关。


### 一个按引用传递的例子(C++)

---

```c++
void call_by_ref(int &r){
	cout<<&r<<endl;	// 0x7fff8cc1decc
	r = 9;
	cout<<&r<<endl;  // 0x7fff8cc1decc
}
int main()
{
	int i = 20;
	cout<<&i<<endl; // 0x7fff8cc1decc
	call_by_ref(i);
	cout<<i<<endl;  // 9
	cout<<&i<<endl; // 0x7fff8cc1decc
   return 0;
}
```
	
可以看到所有的地址都是一样的，因为形参就是一个别名，直接通过地址来操作，对于主函数也是可见的。


### 一个按共享对象传递的例子(JS)

---


* 通过引用的副本修改内容，函数内部 o 还是持有对 obj 的引用
	
	```
	var obj = {x : 1};
	function foo(o) {
	    o.x = 200;
	}
	foo(obj);
	console.log(obj.x); // 200
	```
* 修改引用的副本本身，函数内部的 o 对 obj 的引用断掉了
	
	```js
	var obj = {x : 1};
	function foo(o) {
	    o = 100;
	}
	foo(obj);
	console.log(obj.x); // 1
	```	

## 定义的澄清


### 复制？赋值？

---


从地址或指针的角度来说：

1. 按值传递：形参和实参表示的都是不同的地址，不同地址存的值是相等的
2. 按引用传递：形参和实参表示的是同一个地址，形参和实参**本身**的地址是一样的
3. 按共享对象传递：形参和实参表示的是同一个地址，形参和实参**本身**的地址是不同的

所以有一种说法，认为“所有的参数传递都是按值传递”，因为地址也可以是值。其实这种说法是不准确的，虽然可以说“所有的参数传递本质都是**复制**”，毕竟地址和引用的复制也是复制，但不应该用“按值传递”的概念来套用一切“复制”，这样反而混淆了不同求值策略所要强调的重点。

这其实也是因为**复制**、**赋值**、**引用**等术语本身定义不够清晰引发的误会。像**引用**在不同的语境下，有时指**别名**，有时指**指针**。知乎上[有个回答](https://www.zhihu.com/question/20628016/answer/86977962)提到**复制**的三个内涵：

* 复制 value （按值传递）
* 复制地址 （按共享对象传递）
* 别名 （按引用传递）

而**赋值**也有两个涵义（传递参数也是一种赋值）。尽管在大多数语言里，都是以`a=b;`的形式表示这两个涵义：

* `change`：改变变量指向的内存地址
* `mutate`：改变变量指向的内存地址里的 value

知道这个区分就清晰多了，不同的求值策略下，对形参的`change`或 `mutate`是否会影响实参？求值策略区分的就是：

1. 复制了什么；
2. 对原来的值有什么影响。

如果把握了这两点，就不会发生歧义。

### 值类型 / 引用类型
---


这两个概念描述的是**传递的内容的类型**：

* 值类型(Value Types)：值类型的变量直接包含值，变量存在栈中。每个实例都保留了一分独有的数据拷贝。

* 引用类型(Reference Type)：由类型的实际值引用表示的数据类型，引用类型的数据存储在内存的堆中。每个实例共享同一份数据来源。

这两个概念容易与求值策略混淆，但理解了求值策略，也是很容易理解的。

## 优缺点

C 语言、Golang 是按值传递；C#、C++ 默认按值传递，提供按引用传递的方式；Java、JavaScript 基本类型是按值传递，引用类型按共享对象传递。（理论上像 C 有指针，这几种方式都是可以模拟的……）从求值策略的差异，也可以看出不同语言的风格。

可以看出按值传递的优点在于，对形参的操作不会影响到调用者，没有副作用，缺点是需要为形参分配额外的内存空间，复制的开销也需要考虑。所以在 go 里，涉及传参就需要注意了，传 slice 比传 array 会快一些（引用类型复制的是底层的 header），传结构体指针比传结构体快一些，因为省去了大量内存的分配（不过，传指针的缺点和按引用传递的缺点是类似的，也需要注意）。

按引用传递的方式，跟按值传递相反，传参的时候没有引发内存复制，效率较高，但带来的副作用是容易出 bug，函数的操作对调用者可见，破坏了封装性；对形参的访问会比较慢，因为需要额外的间接寻址；有可能影响对象的声明周期，不利于自动垃圾回收。

按共享对象传递像是了结合了前两种方式，试图达到灵活度和性能之间的平衡，方便编译器和 GC 可以做出更好的管理。这个概念的出现也是对前两种方式的补充。

不管如何，都要了解自己使用的工具的特性，才能写出保证正确性和效率的代码。



## 参考

* [为什么 Java 只有值传递，但 C# 既有值传递，又有引用传递，这种语言设计有哪些好处？](https://www.zhihu.com/question/20628016/answer/28970414)
* [JS中的值是按值传递，还是按引用传递呢？](https://segmentfault.com/a/1190000005794070)
* [值传递, 指针传递 这是一个问题](https://leokongwq.github.io/2017/01/22/golang-param-pass-value-or-point.html)
