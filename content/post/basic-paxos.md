---
title: "Basic Paxos 总结"
date: 2022-03-22T22:46:11+08:00
draft: false
---


Paxos 解决什么问题？

对于一个多节点的分布式系统，客户端写入一个值，得到ok的返回之后，希望这个值是不变的、持久化的。而且期待不管从哪个节点读，都是一致的。

复制解决什么问题？

高可用性：冗余数据，防止单点故障

降低延迟：把数据复制到不同的地理位置，方便客户端更快地读取

伸缩性：提高机器副本从而提高吞吐量

## 几种复制方式

### 1 主从异步复制

主节点收到客户端的写请求，把数据落盘，然后响应客户端ok，再把数据复制到其他节点。

问题：响应ok的时刻，从节点总是落后于主节点的，加入主节点当机，客户端的写入就丢失了，因为从节点没来得及写入副本。

### 2 主从同步复制

主节点收到客户端的写请求，把数据落盘，把数据复制到其他节点，得到从节点的响应后，再响应客户端ok。

问题：主节点会阻塞在从节点的处理上，一方面性能会下降，需要等待网络以及从节点的写盘，另一方面，当从节点当机，主节点就不可用了。

### 3 主从半同步复制

主节点收到客户端的写请求，把数据复制到足够多的机器上，而不是全部，得到部分从节点的确定后，再响应客户端ok。

问题：有可能从库没有完整的数据

### 4 多数派读/写

每条数据写入到半数以上的节点上，读也是要读半数以上的节点。

假设有3个节点 node-1,node-2,node-3，客户端需要写入到至少2个节点才算成功。


## 多数派读/写的问题

### 1 两次写入到不同的2个节点，其中有一个节点会被覆盖

比如

```
// 对 node-1, node-2 都写入了a=x
node-1，a=x;node-2,a=x;node-3,null

// 第二次对node-2, node-3写入了a=y
node-1，a=x;node-2,a=y;node-3,a=y

// 读 node-1，node-2 ,从 node-1 得到 a=x，从 node-2 得到 a=y，无法确定哪条数据是对的。
```

解决：使用全局时间戳，写入的时候对每个数据设置一个全局递增的时间戳或者版本号。已更新的时间戳或更大的版本号为准，也就是 最后写入胜利（LWW）。


```
node-1 , a=null , v0; node-2 , a=null, v0; node-3 , a=null , v0; 

// 对 node-1, node-2 都写入了a=x
node-1 , a=x , v1; node-2 , a=x , v1; node-3 , a=null , v0; 

// 第二次对node-2, node-3写入了a=y
node-1 , a=x , v1; node-2 , a=y , v2; node-3 , a=y , v2; 

// 读 node-1，node-2 ,从 node-1 得到 a=x，v1 从 node-2 得到 a=y，v2。v2>v1，所以 a=y 是正确的
```


### 2 单个客户端写的原子性难以保证

因为客户端需要写多个节点，有可能写的过程中客户端崩溃，没有写入超过半数，系统里的数据会产生不一致。

```
node-1 , a=null , v0; node-2 , a=null, v0; node-3 , a=null , v0; 


// 对 node-1, node-2 都写入了a=x
node-1 , a=x , v1; node-2 , a=x , v1; node-3 , a=null , v0; 

// 二次对node-2, node-3写入了a=y，但只有node-3写成功了，客户端崩溃或出错，没有写入 node-2
node-1 , a=x , v1; node-2 , a=x, v1; node-3 , a=y , v2; 

// 读 node-1，node-2 读到是a=x
// 读 node-2, node-3 得到 a=y（因为 node-3的时间戳更新，v2>v1）
```

又产生不一致。对于客户端而言，这是不确定的状态。同时系统里的数据被污染了。

如果客户端崩溃，理想的状况是，node 里的值还是确定的，而不是部分写入。

### 3 两个客户端并发读取-修改-写回导致丢失更新

我们期待一个值的每个版本只能被写入一次，这个值一旦被确定（返回客户端ok）后，就不可以再被更改。

所以每次写之前，客户端都要进行一次读，获取最新的值，和最新的版本，并选取一个大于当前的版本，不能更改过去的版本的值。

客户端 A 对 a 增 1，B 对 a 增 2，并发地执行，会发生 丢失更新，即 A 对 a 某个确定版本的写入，会被 B 覆盖，

自增操作，一般需要读取-修改-写回，这三个如果不是原子操作，在并发的情况下就有可能发生丢失更新。

写回的值依赖于读到的值，如果读到的值已经被修改了，那么这时候依赖旧值的值就不能写入，否则就会覆盖已经发生的修改。

```
// A 读 node-1，node-2，得到 a=0，v0
// B 读 node-2，node-3，得到 a=0，v0

node-1 , a=0 , v0; node-2 , a=0 , v0; node-3 , a=0 , v0; 


// A 将 a=1 写入 node-1，node-2

node-1 , a=1 , v1; node-2 , a=1 , v1; node-3 , a=0 , v0; 


// B 将 a=3 写入  node-2，node-3 ，这里应该不能写入，因为 1. 会覆盖 A 的更新；2. B 依赖的是一个旧的值（v0版本）
// B 必须再读一次得到新版本的值，才能保留 A 的更新，并且保证计算是正确的
// B 读 node-2，node-3，得到 a=1，v1，基于 v1 的 a 计算出正确的 a=3，并写入
node-1 , a=1 , v1; node-2 , a=3 , v2; node-3 , a=3 , v2; 
```

一般对于丢失更新，在传统的数据库中，有几种处理办法：

1. 原子操作（CAS）

    保证 读取-修改-写回 是一次性做完的，那么其他客户端或者线程就不会读到旧的值。

    ```
    UPDATE counters SET value = value + 1 WHERE key = 'foo';
    ```

2. 显式锁定

    比如在数据库中使用 FOR UPDATE 显式加锁

    ```
    SELECT * FROM figures
    WHERE name = 'robot' AND game_id = 222
    FOR UPDATE;
    ```

在分布式场景下，原子操作很难做到。那可以加锁吗？

尝试使用 2PC（两段提交协议）看看：

客户端作为协调者，node 作为参与者。

第一阶段，客户端 A 告诉多数 node 准备修改了，先锁定资源；

第二阶段，客户端 A 把修改提交给多数 node，确认更新值。

这里的问题在于怎么“锁定资源”，让 B 在发现资源被锁定的情况下，不再继续操作。也就是让 B 能检测到并发冲突。

### 多数派读写总结

到目前为止，我们尝试多数派读/写的方式，加上版本号和最后写入胜利的机制来确定最终值。

每次写入前都要读取一次，获得最新版本，然后基于新版的值计算并写入。

遇到的问题是：
1. 单客户端的原子性难以保证 
2. 多客户端并发的情况下，没法保证读到最新版本的值，会使之前正确的写入丢失
3. 尝试用 2PC 来解决丢失更新问题，但如何检测冲突并不确定

## Basic Paxos 

让存储节点记住谁最后1次做过“写前读取”，并拒绝之前其他的“写前读取”的写入操作。

也就是说，不仅是 最后写入胜利，还要通过 最后读取 来确定写入资格。

在写之前读一次，节点需要记住最近的一次读取是谁读的，并拒绝其他的写入。

所以 node 可以在 2PC 的第一阶段，记住读取的客户端，在第二阶段，检查写入的客户端是不是第一阶段记住的。

下面讨论一下 Paxos 的算法：

首先 Paxos 会定义两个phase，三种角色。

proposor：接受客户端的请求，负责发起两个 phase，更新值。

acceptor：负责响应两个 phase，检查 proposor 发过来的信息和本地的信息，来确定是否可以写入。

learner：用于记录最终确定的值，不是必要的角色。

一般 proposor 和 acceptor 都是在同一个 node 上。

两个 phase 分别是 prepare 和 accept 阶段，这里用 phase1 和 phase2 指代。类似 2PC 的两个阶段。

每个 acceptor 会存三个变量 accepted proposal accepted value， min proposal ID。

proposal ID 是全局递增的，代表了每一次 phase1 发起的提议。

acceptedProposal，acceptedValue 分别是这个 acceptor 上一次接受和保存的 proposal ID 和值。

minProposal 表示 acceptor 在 phase1 同意的提议的 ID。

Paxos 算法只会确定一个 value，确定的 value 不可以再被更改。可以有多个提案并发进行，但是最终只有一个提案会胜出。


phase1

1. proposor 选取一个 proposal ID，广播给所有的 node，发布一个提案，告诉大家我准备更新 value 了
2. acceptor 收到这个 proposal ID，和本地的 minProposal 进行比较
    
    2.1 假如收到的 proposal ID <= minProposal ID, 则返回 no（或者不应答），拒绝此提案
    
    2.2 假如收到的 proposal ID > minProposal， 将 minProposal 设置为该 proposal ID，并返回yes，带上本地的 acceptedProposal 和 acceptedValue

phase2

3. proposor 收到超过半数的 phase1 yes应答

    3.1 如果响应里的 acceptedValue 不为空，把 value 设置成 acceptedValue，并广播 （proposal ID，value）

    3.2 如果所有响应里的 acceptedValue 都为空，则可以随意确定 value，广播 （proposal ID，value）

    3.3 如果没有收到半数应答，说明有一半的 node 失联，算法会停止

    3.4 收到超过半数的 no，回到步骤 1

4. acceptor 收到 phase2 请求，检查 proposal id 
   
   4.1 如果 proposal ID >= minProposal，则写入新的 proposal id 和 value，并返回(proposal ID)
   
   4.2 否则返回no

5. proposor 收到来自 acceptor 超过半数的响应
    5.1 如果返回 proposal ID > 本地的 proposal ID，则回到步骤1
    5.2 否则表示自己发布的 value 已经被接受


说明：

2 对于 acceptor 一旦同意提案，意味着做出了两个承诺：不再应答 Proposal ID 小于等于当前提案的 Propose（phase1请求） ，不再应答 Proposal ID 小于当前提案的 Accept请求（phase2 请求）

2.2 中存储 proposal ID 的目的，是为了 phase2 服务的，phase2 只会接受大于等于该 proposal ID 的写入了。

3.1 phase1 得到的响应里有 value，说明有其他的 proposor 存在，尽管本 proposor 无法确定其他的 proposor 是否写成功，但任何已经写入的值都不可以被更改，所以本 proposor 会广播看到的最大 proposal ID 对应的值，自己失去了写自己 value 的权力。这个 proposor 相当于帮助已经传播已经写入的值到每个 node。

3.2 所有响应的 value 为空，意味着这个系统是新的，还没有任何写入，那 proposor 就可以安全地写入自己的 value

5.1 响应里有比自己 proposal ID 更大的，说明有其他 proposor 成功写入了


简单画个流程图

```
                            phase1
                                +-----------------+
                                |                 |
                                |  proposor       |
 +----------------------------->|  n=pick a proposal ID
 |                              |  propsal(n)     +<---------------------------------------------------------------+
 |                              |                 |                                                                |
 |                              +--------+--------+                                                                |
 |                                       |                                                                         |
 |                                       |                                                                         |
 |                                       |                                                                         |
 |                                       |                                                                         |
 |                              +--------v--------+                                                                |
 |                              |                 |                                                                |
 |                n<minProposal |  acceptor       |      n>=minProposal and acceptedValue!=null                    |
 |                  +-----------+                 +---------------------------+                                    |
 |                  |           |                 |                           |                                    |
 |                  |           |                 |                           |                                    |
 |                  |           +--------+--------+                           |                                    |
 |                  |                    |                                    |                                    |
 |                  |         n>=minProposal and acceptedValue==null          |                                    |
 |                  |                    |                                    |                                    |
 |                  |                    v                                    v                                    |
 |           +------v------+    +-------------------+                +----------------------+                      |
 |           |             |    |                   |                |                      |  v                   |
 |           |return no    |    | minProposal=n     |                | minProposal=n        |                      |
 +-----------+             |    | return(acceptedProposal，null）    | return(acceptedProposal，acceptdValue)      |
             |             |    |                   |                |                      |                      |
             +-------------+    +---------+---------+                +----------------------+                      |
                                          |                                                                        |
                                          |                                                                        |
                                          |                                                                        |
                                          |                                                                        |
                                          |                                                                        |
                                          |                                                                        |
                                          v                                                                        |
           phase2       +------------------------------------------+                                               |
                        |  proposor                                |                                               |
                        |                                          |                                               |
                        |      如果响应里的 acceptedValue 不为空，把 value|设置成 acceptedValue，并广播 （proposal ID，value）      |
                        |                                          |                                               |
                        |      如果所有响应里的 acceptedValue 都为空，则可以随意确定 value，广播 （proposal ID，value）                 |
                        |                                          |                                               |
                        +-----------------+------------------------+                                               |
                                          |                                                                        |
                                          |                                                                        |
                                          |                                                                        |
                                          |                                                                        |
                                          |                                                                        |
                                          |                                                                        |
                                          v                                                                        |
                                   +--------------+                                                                |
        n<minProposal              |              |                                                                |
       +---------------------------+ acceptor     |                                                                |
       |                           |              |                                                                |
       |                           |              |                                                                |
       |                           +------+-------+                                                                |
       |                                  |                                                                        |
       |                                  |                                                                        |
       |                                  |                                                                        |
       |                                  |                                                                        |
       |                           n>=proposal                                                                     |
       |                                  |                                                                        |
+------+--------+                         |                                                                        |
|               |                         |                                                                        |
| return no     |                         |                                                                        |
|               |                         v                                                                        |
|               |      +--------------------------------------------+                                              |
|               |      |                                            |                                              |
+------+--------+      | acceptors                                  |                                              |
       |               |                                            |                                              |
       |               | minProposal=n acceptedProposal=n           |                                              |
       |               | acceptedValue=value                        |                                              |
       |               |                                            |                                              |
       |               | return(proposal ID)                        |                                              |
       |               |                                            |                                              |
       |               +------------------+-------------------------+                                              |
       |                                  |                                                                        |
       |                                  |                                                                        |
       |                                  |                                                                        |
       |                                  |                                                                        |
       |                                  |                                                                        |
       |                                  v                                                                        |
       |                            +--------------+                                                               |
       |                            |proposors     |       未超过半数                                              |
       +--------------------------->|              +-------------------------------------------------------------->+
                                    |              |
                                    +-----+--------+
                                          |
                                          |
                                          | 超过半数
                                          |
                                          v
                                    +--------------+
                                    |              |
                                    |  success     |
                                    |              |
                                    |              |
                                    +--------------+

```

phase1 里 acceptor 存储 minProposal 是一个关键。minProposal 意味着最近一个尝试写的 proposal 的 ID，也意味着 phase2 会用 minProposal 来决定哪些可以写入。从而解决可能的并发冲突。

acceptor 返回 value 值也很重要，因为已经写入的值不可以被覆盖，所有返回 value 值也是告诉 proposal 不能再写入了。

这两点实现了写入的“互斥”。acceptor 通过 minProposal 来记录最后一个读者； proposor 通过 value 来感知是否存在其他竞争者

换句话说，从这几个变量的角度，proposor 要成功写入，需要满足两个条件：

1. 系统里没有被写过值，返回的 value 为空
2. proposor 是最后一个读者，它的 proposal ID 最大，并记录到 acceptors 中的 minProposal 中

对于 basic paxos，只要 value 被确定下来了（被多数节点接受），以后不管执行多少轮 paxos，这个 value 都不会改变

回到上一节遇到的几个问题，看 Paxos 有没有解决：

1. 单客户端的原子性难以保证：proposor 如果在 phase1 挂掉，不会影响系统里已有的 value，可以认为是失败；如果在 phase2 挂掉，要么是写入超过半数，要么是没有超过半数，我们可以确定状态都是正常的，没有中间状态。再一次运行 Paxos 也可以确定下来，
2. 多客户端并发的情况下，没法保证读到最新版本的值，会使之前正确的写入丢失：并发的两个写入只会有一个成功。如果是 X Y 交替运行 phase1 的情况，X 运行 phase2 时会因为 Y 更新了 minProposal 而被拒绝。但这里还存在一个活锁的问题。
3. 尝试用 2PC 来解决丢失更新问题，但如何检测冲突并不确定：通过 minProposal 和 acceptedValue 来检测冲突。

从上面看 basic paxos 有两个明显问题：

1. 活锁：有可能两个 proposor，轮流用更高的 proposal ID 运行 phase1，导致两者都没法进入 phase2，无法确定谁可以写入，形成活锁
2. 性能：每一次写入都需要经过两轮 RPC，两次落盘。性能较差

针对这两个问题，mutil paxos 和 raft 都进行了解决。

主要是引入了 leader 的概念，只有 leader 才能写，就不会有多个写者反复竞争了。

而 phase1 主要的目的也是获得写权限，phase1 实际上在选举阶段进行，而不需要在每次写入进行了。

leader 是已经获得写权限的角色，在写入的时候直接运行 phase2，从而提升了性能。

相较 basic paxos 只能运行一个提案、决定一个值的情况，mutil paxos 和 raft 可以运行多轮提案，同步多个值，或者说日志流，更加实用。

实现 mutil paxos/raft，则需要考虑 1. 怎么实现选举leader 2. 如何同步日志流。

利用 paxos 也可以实现 paxosLease 算法，这也是一个可用来选举 leader 的方式。

## 总结

这篇文章主要是讨论下怎么解决多副本同步变化的数据的问题，考察主从同步复制、主从异步复制、主从半同步复制、多数派读/写怎么解决问题和存在哪些不足。

同时讲解了 basic paxos 算法，看 paxos 怎么解决多副本复制存在冲突的问题，

也介绍了 basic paxos 会存在的问题，通过问题引入 mutil paxos 和 raft。

basic paxos 实际上是一个基于多数派读写、不断重复的 2PC 算法，它可以处理多个提案的冲突，最终得出一个提案，写入一个确定的值，且保证确定后不会被更改，保证强一致性。


### Ref

[可靠分布式系统-paxos的直观解释](https://blog.openacid.com/algo/paxos/)

[PaxosRaft 分布式一致性算法原理剖析及其在实战中的应用](https://github.com/hedengcheng/tech/tree/master/distributed)

[《软件架构设计》第11章 多副本一致性](https://book.douban.com/subject/30443578/)

[《数据密集型应用系统设计》第7章 事务](https://book.douban.com/subject/30329536/)

[画图工具 asciiflow](asciiflow.com)    