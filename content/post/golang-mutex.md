---
title: "Golang Mutex"
date: 2022-04-04T00:04:19+08:00
draft: false
---


1. 有两种模式：正常模式和饥饿模式。正常模式会先自旋再通过信号量排队等待；饥饿模式会严格按照先入先出的顺序。
2. 为什么需要有两种模式？golang的锁是通过自旋+信号量的方式实现的。g获取锁需要先自旋一定次数，再放到信号量等待。当锁释放，会唤醒信号量队头的g。这个g会和新来的g产生竞争，新来的g处于自旋状态，更容易抢到锁，队列中的g会被饿死。性能虽高，但是公平性低。所以引入了饥饿模式解决饥饿问题。
3. 为什么后来者有优势？
    1. 后来者在cpu上自旋，更有优势
    2. 被唤醒的g每次只有一个，自旋的有很多
   
4. 数据结构：由 state 和 sema 组成，零值可用。零值表示解锁状态。

    sema表示信号量

    state低三位，locked表示是否加锁，woken表示是否有g唤醒，starving表示是否进入饥饿模式。这3位以外的位表示有多少g在排队

5. 加/解锁首先会进入 fastpath，原子操作改变 state。如果没有成功再进入 slowpath

    ```
    // 加锁
        if atomic.CompareAndSwapInt32(&m.state, 0, mutexLocked) {
            // 直接对释放的锁加锁成功
            return
        }
        m.lockSlow()

    // 解锁
        new := atomic.AddInt32(&m.state, -mutexLocked)
        // new等于0意味着没有g在排队
        if new != 0 {
            m.unlockSlow(new)
        }
    ```


## lockSlow

1. 先进入自旋，然后判断是否进入饥饿模式，把g放到信号量中等待
2. 进入自旋：
   1. woken置为1 ，防止唤醒太多g
   2. do_spin()自旋，调用30次 PAUSE 指令
3. g进入自旋的条件：
   1. 处于正常模式
   2. 运行在多 CPU 的机器上；
   3. 当前 Goroutine 为了获取该锁进入自旋的次数小于四次；
   4. 当前机器上至少存在一个正在运行的处理器 P 并且处理的运行队列为空；
4. 退出自旋后做什么：保存旧state为old，根据 state 的值，原子操作设置新的state 
    1. woken置为0
    2. 如果 old 处于加锁或者饥饿，则排队规模+1，
    3. 如果锁处于正常模式已经释放，则加锁。（原子操作成功后则退出）
    4. 如果等待时间大于1ms，则设置starving为1

5. 原子操作的结果：

    设置成功，休眠。把自己放入信号量中等待，如果是入队过的，则放到队头，否则放在队尾；

    设置失败，意味着state被修改过。重新回到lockSlow，从5循环

6. 被唤醒后做了什么：

    如果处于正常模式，自旋抢锁

    如果处于饥饿模式，排队规模-1，判断是否满足退出饥饿模式的条件

7. 退出饥饿模式的条件：
   
   g等待的时间小于1ms；

   等待队列为空

## unlockSlow

1. 处于正常模式：检查是否需要唤醒g；处于饥饿模式：直接唤醒g
2. 如果满足以下3点，则不需要唤醒等待中的g，直接返回
    1. 处于饥饿模式 
    2. woken==1 
    3. 等待队列为空，
3. 否则抢占 woken，抢到了则唤醒一个g


## 读写锁 RWMutex


1. 数据结构：

    ```
    type RWMutex struct {
        w           Mutex  // 用于互斥写操作
        writerSem   uint32 // 写者信号量
        readerSem   uint32 // 读者信号量
        readerCount int32  // 有读者则加1，如果是负值说明有写者加锁；通过减去 rwmutexMaxReaders 实现阻塞读者
        readerWait  int32  // 标记排在写操作g前面的读操作goroutine个数
    }

    const rwmutexMaxReaders = 1 << 30 
    ```

2. 加读锁与加读锁之间不互斥；加写锁与加写锁互斥；加读锁和加写   锁互斥

3. `写者之间，通过 mutex 实现互斥`。

4. `RLock 通过判断 readerCount 是否等于负数发现写者的存在`。Lock 会将 readerCount 减去 rwmutexMaxReaders。RLock 发现 readerCount<0，就把自己放到信号量队列中休眠

5. RLock 对 readerCount+1，RUnlock 对 readerCount-1，将 readerWait 减 1。

6. RUnlock发现readerCount<0，发现有写者在等待。readerWait如果等于0，会通过 writerSem 唤醒写者

7. Lock 先用 mutex 阻塞其他的写者；然后将readerCount变成负值，阻塞读者；原来的readerCount不等于0，意味着有读者，应该睡眠，原来的readerCount加到readerWait。`Lock 通过查看 readerCount 是否等于0 来发现读者的存在`。

8. Unlock 将 readerCount 加上 rwmutexMaxReaders，恢复为正值，通过 readerSem 唤醒所有的读者，解锁 mutex


# Ref

go1.17.6 `go/src/sync/mutex.go` 

go1.17.6 `go/src/sync/rwmutex.go `

[同步原语与锁](https://draveness.me/golang/docs/part3-runtime/ch06-concurrency/golang-sync-primitives/)

[【Golang】Mutex秘籍](https://www.bilibili.com/video/BV15V411n7fM?p=3)