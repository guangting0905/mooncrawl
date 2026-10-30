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
pub fn Bloom::new(expected_items : Int32) -> Bloom {
  let bits = if expected_items < 64 { 1024 } else { expected_items * 16 }
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
