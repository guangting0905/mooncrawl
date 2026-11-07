// 布隆过滤器：大规模 URL 去重的内存友好方案。
//
// 一个中型站点动辄数十万链接，用 Map/HashSet 精确去重内存开销大；
// 抓取场景允许极低概率的重复抓取，因此布隆过滤器是更合适的权衡。
// 召回策略上，绝对不漏（已抓取的 URL 一定命中），允许约 0.07% 误报
// （个别未抓取的 URL 被跳过，对采集结果影响可忽略）。
//
// 位存储用 Array[UInt64] 手工打包，而不是 Array[Bool]：后者每个元素占
// 一个槽位（native 下 1 字节），10 万 URL 要占 1.6 MB，与「16 bit/元素」
// 的说法差 8 倍。打包后 10 万 URL 约 200 KB。

///|
/// 固定容量布隆过滤器。
pub struct Bloom {
  priv words : Array[UInt64] // 位存储，每字 64 位
  priv m : Int32 // 位总数 = words.length() * 64
  priv k : Int32 // 哈希函数个数
}

///|
/// 创建期望容纳 `expected_items` 个元素的过滤器。
///
/// 每元素分配 16 位、7 个哈希函数，理论误报率
/// `(1 - e^(-7/16))^7 ≈ 0.070%`；10 万元素约 200 KiB。
///
/// 容量一旦超出预期，误报率会迅速上升（超过容量 5 倍时接近 40%），
/// 表现为「把没见过的 URL 当成见过而丢弃」。调用方应通过
/// `saturation_permille()` 观察实际负载，必要时重建更大的过滤器。
/// 位数组上限 32 MiB（约 1670 万元素），避免 Int32 乘法溢出。
pub fn Bloom::new(expected_items : Int32) -> Bloom {
  let want : Int32 = if expected_items < 1 { 1 } else { expected_items }
  let bits_wanted : Int64 = want.to_int64() * 16L
  let bits_cap : Int64 = 268_435_456L
  let bits : Int32 = if bits_wanted > bits_cap {
    bits_cap.to_int()
  } else if bits_wanted < 1024L {
    1024
  } else {
    bits_wanted.to_int()
  }
  let word_count = (bits + 63) / 64
  let words : Array[UInt64] = []
  let mut i = 0
  while i < word_count {
    words.push(0UL)
    i = i + 1
  }
  { words, m: word_count * 64, k: 7, }
}

///|
/// 单字的置位数量（SWAR popcount）。
fn popcount64(x : UInt64) -> Int32 {
  let mut v = x
  v = v - ((v >> 1) & 0x5555555555555555UL)
  v = (v & 0x3333333333333333UL) + ((v >> 2) & 0x3333333333333333UL)
  v = (v + (v >> 4)) & 0x0F0F0F0F0F0F0F0FUL
  ((v * 0x0101010101010101UL) >> 56).to_int()
}

///|
/// 位数组的填充率（千分比，0–1000）。
///
/// 设计容量内应远低于 500；接近 1000 时几乎每个新键都会被误判为已见，
/// 调用方应停止扩充并重建更大的过滤器。O(位数组字数)，十万级容量下
/// 约 1 微秒。
pub fn Bloom::saturation_permille(self : Bloom) -> Int32 {
  let mut set : Int64 = 0L
  for w in self.words {
    set = set + popcount64(w).to_int64()
  }
  let total : Int64 = self.m.to_int64()
  if total <= 0L {
    return 0
  }
  (set * 1000L / total).to_int()
}

///|
fn fnv1a64(s : String, seed : UInt64) -> UInt64 {
  let prime = 1099511628211UL
  let mut h = seed
  for c in s {
    h = h ^ c.to_int().to_uint64()
    h = h * prime
  }
  h
}

///|
/// 置位：字索引 + 字内偏移。
fn set_bit(buf : Array[UInt64], idx : Int32) -> Unit {
  let w : Int32 = idx / 64
  let bit : Int32 = idx % 64
  let word : UInt64 = buf[w]
  let mask : UInt64 = 1UL << bit
  buf[w] = word | mask
}

///|
fn get_bit(buf : Array[UInt64], idx : Int32) -> Bool {
  let w : Int32 = idx / 64
  let bit : Int32 = idx % 64
  let word : UInt64 = buf[w]
  let shifted : UInt64 = word >> bit
  (shifted & 1UL) == 1UL
}

///|
/// 加入一个键。
pub fn Bloom::add(self : Bloom, key : String) -> Unit {
  let h1 = fnv1a64(key, 14695981039346656037UL)
  let h2 = fnv1a64(key, 1099511628211UL) | 1UL
  let m64 = self.m.to_uint64()
  let mut i = 0
  while i < self.k {
    let idx = ((h1 + i.to_uint64() * h2) % m64).to_int()
    set_bit(self.words, idx)
    i = i + 1
  }
}

///|
/// 判断键是否可能已添加。返回 false 表示一定未添加过。
pub fn Bloom::maybe_contains(self : Bloom, key : String) -> Bool {
  let h1 = fnv1a64(key, 14695981039346656037UL)
  let h2 = fnv1a64(key, 1099511628211UL) | 1UL
  let m64 = self.m.to_uint64()
  let mut i = 0
  while i < self.k {
    let idx = ((h1 + i.to_uint64() * h2) % m64).to_int()
    if !get_bit(self.words, idx) {
      return false
    }
    i = i + 1
  }
  true
}
