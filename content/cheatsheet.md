---
title: "Cheatsheet"
date: 2018-03-18T14:02:01+08:00
draft: false
---
# Cheatsheet

---

## Linux


1. 安装 deb 文件：
	
     `sudo dpkg -i [name].deb`
	
     `sudo apt-get install -f` （修复依赖关系）

2. linux 查找文件

     `find [path] -name "*.log" `
	
3. ubuntu（桌面版） 在终端输入`xkill`，鼠标变成`x`，点击 GUI 程序，可强制关闭之


4. 调用自己定义的编辑器来编辑当前命令行:

      `ctrl-x ctrl-e`

    设置自己的默认编辑器：

      `export EDITOR=vi` 
	
5. shell 脚本报错：`... /bin/sh^M: bad interpreter: No such file or directory`

      解决：

      `vim [name.sh]`
	
      `:set ff` 查看文件格式，若看到输出`fileformat=dos`，可`:set ff=unix`修改为 unix 格式
	
6. 本地文件传输到远程机器

      `scp -P [port] /path/to/source [user]@[ip]:/path/to/target`
	
7. 不挂断地运行命令

      `nohup [command] [arg..] [&]`
        
      例如：`nohup hugo server  --buildDrafts >> hugo.log 2>&1 &` 后台运行 hugo，将标准输出和标准错误重定向到 hugo.log 中，该命令将返回进程号：`[1] 24102`。
        
      使用`jobs`命令可以看到该后台进程（当前终端有效）：`[1]  + running    nohup hugo server --buildDrafts >> hugo.log 2>&1`
	
      使用`fg %1`（%1 为 jobs 编号而非 PID）可以使后台作业切换到前台 

## 数据库

7. mongo shell 查询 collections

       `db.[collection].find();`

       删除某一条文档：
	
       `db.[collection].remove({"[key]":"[value]"});`
	
18. cockroachDB 导入 sql 脚本：
	
    `cat /path/to/schema.sql | cockroach sql -d [db] -u [user] --insecure`
	
	
##  Git

8. 改变最近一次提交：

    修改并`git add/rm [file]`后，`git commit --amend`，也可以修改 commit 说明


10. 落后远程分支几个版本，强行回退：

     1. `git reset [commitID]`，到上个版本
     2. `git stash`，暂存修改
     3. `git push --force`, 强制push,远程的最新的一次commit被删除
     4. `git stash pop`，释放暂存的修改，开始修改代码
     5. `git add . `-> `git commit -m "massage"` -> `git push`

11. 从某个 commit 中复制某个文件到暂存区:

       `git reset [commit-hash] file.txt` 

       `git add file.txt` 的逆操作，可用来取消暂存：
	
       `git reset (HEAD) file.txt`

12. git 的三棵树：

      树                         | 用途        
      ---------------------|-----
      HEAD                    | 上一次提交的快照，下一次提交的父结点
      Index                     | 预期的下一次提交的快照（也就是暂存区）
      Working Directory | 沙盒

13. `git reset` 命令会以特定的顺序重写这三棵树，在你指定以下选项时停止：

      1. 移动 HEAD 分支的指向 （若指定了 `--soft`，则到此停止）
      2. 使索引看起来像 HEAD （若未指定 `--hard`，则到此停止；即指定 `--mixed` 或默认情况）
      3. 使工作目录看起来像索引 (指定`--hard`，危险操作)

14. 查看 git 远程仓库 URL：

     `git remote -v`


	
16. git 查看某个文件的修改历史

     1. `git log -p [filename]`
       查看文件的每一个详细的历史修改
	
     2. `git log --pretty=oneline [filename]`
       每一行显示一个提交，先显示哈希码，再显示提交说明。
	
     3. `git blame [filename]`
       查看文件的每一行是哪个提交最后修改的。
	
17. `git reflog`:
	
     当你 (在一个仓库下) 工作时，Git 会在你每次修改了 HEAD 时悄悄地将改动记录下来。当你提交或修改分支时，reflog 就会更新。


## Go

1. 可以使用 `go tool vet -shadow you_file.go` 检查幽灵变量

2. go get 只下载不安装：

    `go get -d`

3. string 和 int 转换 

    ```go
    //string到int  
    int,err:=strconv.Atoi(string)  
    //string到int64  
    int64, err := strconv.ParseInt(string, 10, 64)  
    //int到string  
    string:=strconv.Itoa(int)  
    //int64到string  
    string:=strconv.FormatInt(int64,10)  
    ```	



