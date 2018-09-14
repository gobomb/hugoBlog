---
title: "Arch Linux 安装记录"
date: 2018-09-09T16:22:20+08:00 
draft: false
description: "以及一些常用命令的记录"
keywords: [Linux]
tags: [Linux,运维,CLI]
categories: [记录]
gitment: true
---

旧笔记本之前是安装着 Windows 10 的，自从工作开始使用 rMBP 之后，就闲置着。我想不如重装成 Linux 系统，当作一个私人服务器用，也可以加深一下对操作系统的理解。很早就听说滚动发行的 Arch Linux 的大名，就想趁机试一试。跟着官方 Wiki 走，大概花了6、7个小时才装好，中间也遇到了一些问题，但那时没有记录下来。用了一段时间后，`/boot`分区不小心被我覆盖了（估计是我使用 lvm 创建物理卷的时候把引导分区给格式化了），导致系统启动不了，一时半会也不会修。

![启动找不到`/boot`目录](grub_rescue.jpeg)

放着有半个月，今天有空干脆格盘重装，再过一遍安装过程，把过程和问题记录下来，下一次遇到问题就不用再去 google。覆盖引导的问题，也是因为我没有把分区规划的信息留下来，后面自己也乱了。而且实际上90%的问题都会重复遇到，做好记录能极大提高效率。

Arch 官方 Wiki 做得真是很好，基本上遇到问题耐心读一读 Wiki 就能够解决。用来学习 Linux 相关知识也特别有用。

整个安装过程的大体步骤

1. 制作安装介质
2. 从安装介质启动
3. 分区和挂载磁盘
4. 下载安装基本包到系统分区中
5. 从安装介质切换到系统
6. 完成基本的设置，并安装引导

分区和安装引导的部分是比较容易出错的，但大部分情况都可以从 Arch Wiki 中找到答案。

# 安装准备

1. 下载 ArchLinux iso 文件

	`https://www.archlinux.org/download/`

2. 制作安装介质

    1. 在 Mac 下安装`pv` （用来查看`dd`的进度）

        `brew install pv`

    2. 找到 U 盘对应的设备 

        `diskutil list`

        我这里是`/dev/disk2`

    3. 查看 U 盘挂载的目录

        `df -h`

    4. 解除挂载

        `diskutil unmountDisk /dev/disk2`

    5. 将 ISO 文件写入 U 盘
        
        `sudo pv -cN source < /Users/cym/Downloads/archlinux-2018.09.01-x86_64.iso | sudo dd of=/dev/rdisk2 bs=4m`

# 启动

1. 将 U 盘插到想要安装的电脑，启动，并按`F2`设置启动顺序

	检查引导方式

	`ls /sys/firmware/efi/efivars`


	如果提示`ls: cannot access '/sys/firmware/efi/efivars': No such file or directory`表明是以`BIOS`方式引导，否则为以`EFI`方式引导。我是以`EFI`方式引导。以下的步骤都是以此为前提。


2. 更新系统时间

	`timedatectl set-ntp true`

# 分区

3. 查看分区情况

	`fdisk -l`

	可以看到输出：
	
	```
	root@archiso ~ # fdisk -l
	
	Disk /dev/sda: 465.8 GiB, 500107862016 bytes, 976773168 sectors
	Units: sectors of 1 * 512 = 512 bytes
	Sector size (logical/physical): 512 bytes / 4096 bytes
	I/O size (minimum/optimal): 4096 bytes / 4096 bytes
	Disklabel type: dos
	Disk identifier: 0x5a192013
	
	Device     Boot     Start       End   Sectors   Size Id Type
	/dev/sda1            2048 209729535 209727488   100G  5 Extended
	/dev/sda2       209729536 500000000 290270465 138.4G  0 Empty
	/dev/sda3       500000768 976773167 476772400 227.4G 83 Linux
	
	
	Disk /dev/sdb: 7.5 GiB, 7990149120 bytes, 15605760 sectors
	Units: sectors of 1 * 512 = 512 bytes
	Sector size (logical/physical): 512 bytes / 512 bytes
	I/O size (minimum/optimal): 512 bytes / 512 bytes
	Disklabel type: dos
	Disk identifier: 0x7e0d49cf
	
	Device     Boot Start     End Sectors  Size Id Type
	/dev/sdb1  *        0 1169407 1169408  571M  0 Empty
	/dev/sdb2         164  131235  131072   64M ef EFI (FAT-12/16/32)
	
	...
	
	```
	 
	
	这里`/dev/sda`是我的硬盘，`/dev/sdb`是我的 U 盘

4. 进行分区

	我是这么规划的:前 512M 用来放引导和`/boot`，再分两个区用`lvm`进行管理，方便以后平滑扩容。
	
	因为有旧的`lvm`的数据，我索性把整个盘都格式化了：
	
	```
	dd if=/dev/zero of=/dev/sdb bs=512 count=1
	```
	
	然后分区：

	a. 创建引导分区
		
		```
		Welcome to fdisk (util-linux 2.32.1).
		Changes will remain in memory only, until you decide to write them.
		Be careful before using the write command.
		
		# 输入 g 创建一个全新的gpt分区表
		Command (m for help): g
		Created a new GPT disklabel (GUID: 947BAFD8-FEC4-9C4C-AB6D-FA8B9CFCBC2F).
		The old dos signature will be removed by a write command.
		
		# 输入 n 创建一个新的分区
		Command (m for help): n
		# 回车使用默认值
		Partition number (1-128, default 1):
		
		# 回车使用默认值
		First sector (2048-976773134, default 2048):
		# 结束扇区填 +512M
		Last sector, +sectors or +size{K,M,G,T,P} (2048-976773134, default 976773134): +512M
		
		# 输入 p 查看分区信息
		Command (m for help): p
		Disk /dev/sda: 465.8 GiB, 500107862016 bytes, 976773168 sectors
		Units: sectors of 1 * 512 = 512 bytes
		Sector size (logical/physical): 512 bytes / 4096 bytes
		I/O size (minimum/optimal): 4096 bytes / 4096 bytes
		Disklabel type: gpt
		Disk identifier: 947BAFD8-FEC4-9C4C-AB6D-FA8B9CFCBC2F
		
		Device     Start     End Sectors  Size Type
		/dev/sda1   2048 1050623 1048576  512M Linux filesystem
		
		Filesystem/RAID signature on partition 1 will be wiped.
		
		# 输入 t 更改分区的文件系统
		Command (m for help): t
		Selected partition 1
		# 输入 1 更改分区的类型为EFI
		Partition type (type L to list all types): 1
		Changed type of partition 'Linux filesystem' to 'EFI System'.
		
		# 输入 p 查看已生效
		Command (m for help): p
		Disk /dev/sda: 465.8 GiB, 500107862016 bytes, 976773168 sectors
		Units: sectors of 1 * 512 = 512 bytes
		Sector size (logical/physical): 512 bytes / 4096 bytes
		I/O size (minimum/optimal): 4096 bytes / 4096 bytes
		Disklabel type: gpt
		Disk identifier: 947BAFD8-FEC4-9C4C-AB6D-FA8B9CFCBC2F
		
		Device     Start     End Sectors  Size Type
		/dev/sda1   2048 1050623 1048576  512M EFI System
		
		Filesystem/RAID signature on partition 1 will be wiped.
		
		# 输入 w 确认修改（在输入 w 之前前面所有的修改都不会真正写入磁盘，输入 w 后操作就生效且不可逆）
		Command (m for help): w
		The partition table has been altered.
		Calling ioctl() to re-read partition table.
		Syncing disks.
		
		# 查看分区信息
		root@archiso ~ # fdisk -l
		Disk /dev/sda: 465.8 GiB, 500107862016 bytes, 976773168 sectors
		Units: sectors of 1 * 512 = 512 bytes
		Sector size (logical/physical): 512 bytes / 4096 bytes
		I/O size (minimum/optimal): 4096 bytes / 4096 bytes
		Disklabel type: gpt
		Disk identifier: 947BAFD8-FEC4-9C4C-AB6D-FA8B9CFCBC2F
		
		Device     Start     End Sectors  Size Type
		/dev/sda1   2048 1050623 1048576  512M EFI System
		
		...
		
		# 格式化
		root@archiso ~ # mkfs.fat -F32 /dev/sda1
		mkfs.fat 4.1 (2017-01-24)
		
		```
		
	b. 创建根分区
		
		我这里用了`lvm`,按照上述类似的步骤（输入 p）创建两个分区（`/dev/sda2`和`/dev/sda3`),然后创建物理卷（`pv`),卷组（`vg`),逻辑卷（`lv`),然后格式化逻辑卷，把根分区(`/`)挂载到逻辑卷上面
		
		```
		# 创建分区 /dev/sda2 和 /dev/sda3
		# 参考上一步
		
		# 创建物理卷
		pvcreate /dev/sda2 
		
		# 卷组名是 root
		vgcreate root /dev/sda2
		
		# 逻辑卷名是 root
		lvcreate -L 45G root -n root
		
		# 创建物理卷
		pvcreate /dev/sda3
		
		# 物理卷加入卷组
		vgextend root /dev/sda3
		
		# 格式化逻辑卷
		mkfs.ext4 /dev/mapper/root-root
		
		```

# 挂载分区

```
mount /dev/mapper/root-root /mnt`


# 因为我是 EFI/GPT 引导方式，所以需要以下步骤
mkdir /mnt/boot

mount /dev/sda1 /mnt/boot
```


此时`df -h`可以看到：

```
...
/dev/mapper/root-root   45G   53M   42G   1% /mnt
/dev/sda1              511M  4.0K  511M   1% /mnt/boot
...
```

`/dev/mapper/root-root`是根目录

`/dev/sda1`是启动目录

# 选择镜像源

`vim /etc/pacman.d/mirrorlist`

在第一行加入中国的镜像源，我加的是浙大的源

`Server = http://mirrors.zju.edu.cn/archlinux/$repo/os/$arch`

# 安装基本包

`pacstrap /mnt base base-devel`

等待下载完成

# 检查挂载情况

`cat /mnt/etc/fstab`

```
# Static information about the filesystems.
# See fstab(5) for details.

# <file system> <dir> <type> <options> <dump> <pass>
# /dev/mapper/root-root UUID=82c37f98-81dc-4c34-9107-4108f6302a3b
/dev/mapper/root-root   /           ext4        rw,relatime 0 1

# /dev/sda1 UUID=BF94-56F2
/dev/sda1               /boot       vfat        rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,utf8,errors=remount-ro   0 2
```


# 切换到新的系统中

`arch-chroot /mnt`



## 1. 设置时区

```
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc
```

## 2. 安装常用包

`pacman -S vim dialog wpa_supplicant ntfs-3g networkmanager`

## 3. 设置语言

`vim /etc/locale.gen`

在文件中找到`zh_CN.UTF-8 UTF-8` `zh_HK.UTF-8 UTF-8` `zh_TW.UTF-8 UTF-8` `en_US.UTF-8 UTF-8`这四行，去掉行首的`#`号，保存并退出。

`locale-gen`

`vim /etc/locale.conf`

添加 `LANG=en_US.UTF-8`

## 4. 设置主机名

`vim /etc/hostname`

```
127.0.0.1   localhost.localdomain   localhost
::1     localhost.localdomain   localhost
127.0.1.1   myhostname.localdomain  myhostname
```

`myhostname`替换为自己想要的主机名


## 5. 设置 root 密码

`passwd root`

## 6. 安装 Intel-ucode

`pacman -S intel-ucode`


## 7. 配置 sshd

`pacman -S sshd`

`vim /etc/ssh/sshd_conf`

修改`PermitRootLogin yes`项允许 root 登录

`systemctl restart sshd`

设置 sshd 开启启动

`systemctl enable sshd`


## 8. 安装Bootloader

安装相关的包：

```
pacman -S os-prober
pacman -S grub efibootmgr
```

因为我把根分区挂在逻辑卷上，需要修改相关的设置，不然引导无法识别逻辑卷：

`vim /etc/mkinitcpio.conf`


```
# 在 MODULES 加入 dm_mod
MODULES=(dm_mod ...)

# 在 mkinitcpio.conf 中加入lvm的钩子扩展（hook）
# 在 HOOKS 中 block 与 filesystem 这两项中间插入 lvm2
HOOKS="base udev ... block lvm2 filesystems"
```

部署grub,生成配置文件：

```
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
grub-mkconfig -o /boot/grub/grub.cfg
```

# 重启

```
exit
reboot
```

到这里就安装完成了,第二次安装其实已经很熟练了，大概半个小时就完事。

再装个 docker，常见的软件都可以用 docker 来跑，这里就先不详细展开了。

# 参考链接

https://www.viseator.com/2017/05/17/arch_install/

http://wiki.archlinux.org/

https://wiki.archlinux.org/index.php/Netctl_(%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87)#.E5.90.AF.E5.8A.A8.E9.85.8D.E7.BD.AE.E6.96.87.E4.BB.B6


# 一些常用到的命令

## 1. 命令行下弹出usb设备：

	```
	pacman -S udisks2
	udisksctl unmount -b /dev/sdb1
	udisksctl power-off -b /dev/sdb
	```

## 2. 挂载iso

`sudo mount -o loop sth.iso /mnt/iso`


## 3. 设置笔记本合盖不休眠

`vim /etc/systemd/logind.conf`

将`#HandleLidSwitch=suspend`改成`HandleLidSwitch=ignore`

重启`systemd-logind`服务：

`systemctl restart systemd-logind`

## 4. 调整屏幕亮度

`echo 100 > /sys/class/backlight/intel_backlight/brightness`

## 5. 设置开机自动连接 Wi-Fi

安装`netctl` Wi-Fi 管理工具：
	
`pacman -S dialog wpa_supplicant netctl wireless_tools wpa_actiond`
	
	
找到当前 Wi-Fi 的配置文件，我这里是`wlp2s0-303`
	
`ls /etc/netctl`
	
设置开机启动服务：
	
`netctl enable wlp2s0-303`

## 6. 通过特定网卡搜索 Wi-Fi

`iwlist [interface] scan | less`

# 一点总结

1. Linux 是很自由的，基本上你想到的问题都会有相关的文档和软件包。（如果找不到解决方案，理论上也可以自己写代码解决，只不过 Linux 社区发展这么久的，常见的问题都有前人做好，只需要你学会使用搜索引擎主动寻求）

2. 磁盘分区还是有一定风险的，不熟练的话总是不敢下手，很多操作实际上是不可逆的。必须得清楚知道自己在干嘛，敲起命令来才放心。

3. “一切皆文件”的 UNIX 思想很有意思。
