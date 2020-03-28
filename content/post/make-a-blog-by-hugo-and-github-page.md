---
title: "用 Hugo 和 GitHub Page 搭建博客"
date: 2017-10-31T16:02:19+08:00
draft: false
description: "搭建博客的过程"
lastmod: 2018-01-01
keywords: [golang]
tags: [hugo]
categories: [记录]
---
图省事，懒得花钱买域名和备案，就用 [GitHub Page](https://pages.github.com/) 来搭博客了。

[hugo](https://gohugo.io/) 是用 Golang 写的静态网站生成器。支持 Markdown 语法。
另一个用js写的同类工具[jekyll](http://jekyll.com.cn/)
比较出名。<br /><br />


## 安装和使用Hugo

* 如果有 Go 环境，直接在终端输入：

```
go get -v github.com/spf13/hugo

hugo new site /path/to/site
```

* `path/to/site`是本地站点目录


* 创建 about 页面：

```
hugo new about.md
```


* 皮肤我用的是 [rockrock](https://github.com/chingli/rockrock)：

```
cd themes

git clone https://github.com/chingli/rockrock
```

## 在本地运行

* 在站点根目录下运行：
  `hugo server --theme=rockrock --buildDrafts`
  <br/>

* 在浏览器访问：
  `http://localhost:1313`
  <br/>

* 这里修改 Markdown 文件可以动态更新，很方便。
  <br/><br/>

## 在 GitHub 上部署
1 在 GitHub 建一个 Repository，命名为 `sidddhartha.gitbub.io`,
`sidddhartha` 为自己的用户名。
<br/>

2 在站点根目录下执行：

```
hugo --theme=rockrock --baseUrl="https://sidddhartha.github.io/"
```

3 将生成的 pubilc 目录里所有文件 push 到 `sidddhartha.gitbub.io` 的 master 分支

```
cd public

git init

git remote add origin https://github.com/sidddhartha/sidddhartha.github.io.git

git add -A

git commit -m "first commit"

git push -u origin master
```

<br/>
4 浏览器访问：https://sidddhartha.github.io
<br/><br/>

## 代码高亮

使用 [highlight.js](https://highlightjs.org/)：

1. 将 highlight.js 下载到本地

2. 把 js 库文件`highlight.pack.js` 复制到 `.../themes/rockrock/static/js/`下面；把 `github.css`复制到 `.../themes/rockrock/static/css/`下面；有多种风格样式，我选择的是 `github` 风格

3.  在`.../themes/rockrock/layouts/partials/header.html`里添加以下代码：

```html
<!-- Highlight.js and css -->
	 <script src="{{ .Site.BaseURL }}js/highlight.pack.js"></script>
	 <link rel="stylesheet" href="{{ .Site.BaseURL }}css/github.css">
	 <script>hljs.initHighlightingOnLoad();</script>
```

highlight.js 会自动检测语言类型，并使用`github`样式。





## 参考文章
* http://www.gohugo.org/
* http://tonybai.com/2015/09/23/intro-of-gohugo/
