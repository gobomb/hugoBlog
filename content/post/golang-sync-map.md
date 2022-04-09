---
title: "Golang Sync Map"
date: 2022-04-04T22:33:49+08:00
draft: false
---

适用的情形是 1. 读多写少 2. 多个g读写的key不同。

使用冗余的 map，来分离读写，相当多了一个缓存。两个map分别为dirty、read，他们的value存的是指针，相当于value是共享的，节省一些内存。

```go
type Map struct {
    // 保护dirty、misses，read的提升过程
	mu Mutex
    // 如果是read中的已知key，不需要加锁
	read atomic.Value 
    // 新加的key会写到dirty中
	dirty map[interface{}]*entry
    // 记录从read未命中，到dirty中去查的次数
	misses int
}

// read对应的数据结构
type readOnly struct {
	m       map[interface{}]*entry
	amended bool 
}

// 表示value的指针
type entry struct {
	p unsafe.Pointer 
}
```  

对dirty的增删查改需要加锁，对read的更新、读、删除则不需要，使用原子操作实现。所以这里性能比一般的map+mutex更好的地方，在于原子操作比mutex快。

```go
func (m *Map) Load(key interface{}) (value interface{}, ok bool) {
	read, _ := m.read.Load().(readOnly)
	e, ok := read.m[key]
	if !ok && read.amended {
		m.mu.Lock()
		// ...
		m.mu.Unlock()
	}
	if !ok {
		return nil, false
	}
	return e.load()
}

func (m *Map) Store(key, value interface{}) {
	read, _ := m.read.Load().(readOnly)
	if e, ok := read.m[key]; ok && e.tryStore(&value) {
		return
	}

	m.mu.Lock()
	// ...
	m.mu.Unlock()
}

func (m *Map) LoadAndDelete(key interface{}) (value interface{}, loaded bool) {
	read, _ := m.read.Load().(readOnly)
	e, ok := read.m[key]
	if !ok && read.amended {
		m.mu.Lock()
		// ...
		m.mu.Unlock()
	}
	if ok {
		return e.delete()
	}
	return nil, false
}
```

对key的更新、读、删除会先对read操作，当从read找不到key时，才加锁到dirty中查找。每次在read没有命中，misses就会加1。

当misses>=len(dirty)时，dirty就会提升为read。dirty本身会被置为nil。


```go
func (m *Map) missLocked() {
	m.misses++
	if m.misses < len(m.dirty) {
		return
	}
    // 把dirty提升为read，dirty置nil，misses清0
    // readOnly的amended此时默认值是fasle
	m.read.Store(readOnly{m: m.dirty})
	m.dirty = nil
	m.misses = 0
}

func (m *Map) Load(key interface{}) (value interface{}, ok bool) {
	read, _ := m.read.Load().(readOnly)
	e, ok := read.m[key]
	if !ok && read.amended {
		m.mu.Lock()
		read, _ = m.read.Load().(readOnly)
        // 加锁后会再检查一次read，防止读read之后加锁之前read发生变化
		e, ok = read.m[key]
		if !ok && read.amended {
            // read中找不到key，到dirty中查找
			e, ok = m.dirty[key]
            // 不管有没有找到，都会记录 misses
			m.missLocked()
		}
		m.mu.Unlock()
	}
	if !ok {
		return nil, false
	}
	return e.load()
}
```

添加新key（read中不存在的key），会加锁并添加到dirty中去。

```go
func (m *Map) Store(key, value interface{}) {
	read, _ := m.read.Load().(readOnly)
	if e, ok := read.m[key]; ok && e.tryStore(&value) {
		return
	}

	m.mu.Lock()
    // 加锁后会再检查一次read，防止读read之后加锁之前read发生变化
	read, _ = m.read.Load().(readOnly)
	if e, ok := read.m[key]; ok {
		if e.unexpungeLocked() {
            // expunged意味着这里的key在read被删除过
            // dirty从read中复制key的时候，没有把被删除的key复制过来
			m.dirty[key] = e
		}
		e.storeLocked(&value)
	} else if e, ok := m.dirty[key]; ok {
		e.storeLocked(&value)
	} else {
        // amended为false，说明dirty需要分配空间
		if !read.amended {
			m.dirtyLocked()
            // amended修改为true
			m.read.Store(readOnly{m: read.m, amended: true})
		}
		m.dirty[key] = newEntry(value)
	}
	m.mu.Unlock()
}

```

read有个amended属性，为true则表示dirty包含read没有的key，为false则表示read刚刚提升过，dirty为nil。这时dirty就需要分配空间，并且把read中未删除的key复制到dirty中（dirtyLocked），然后将read.amended置为true。

```go
func (m *Map) dirtyLocked() {
	if m.dirty != nil {
		return
	}

	read, _ := m.read.Load().(readOnly)
    // 给dirty分配内存
	m.dirty = make(map[interface{}]*entry, len(read.m))
    // 把read中未删除的key复制到dirty中
	for k, e := range read.m {
        // 删除过的key会把对应的value标记为expunged
		if !e.tryExpungeLocked() {
			m.dirty[k] = e
		}
	}
}
```

# Ref

go1.17.6 go/src/sync/map.go