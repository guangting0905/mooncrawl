// 布隆过滤器：大规模 URL 去重的内存友好方案。
//
// 一个中型站点动辄数十万链接，用 Map/HashSet 精确去重内存开销大；
// 抓取场景允许极低概率的重复抓取，因此布隆过滤器是更合适的权衡。
// 召回策略上，绝对不漏（已抓取的 URL 一定命中），允许约 0.1% 误报
// （个别未抓取的 URL 被跳过，对采集结果影响可忽略）。

///|
/// 固定容量布隆过滤器。
pub struct Bloom {
  priv bits : Array[Bool]
  priv m : Int
  priv k : Int
}

///|
/// 创建期望容纳 `expected_items` 个元素的过滤器。
/// 每元素分配 16 位、7 个哈希函数，误报率约 0.06%。
pub fn Bloom::new(expected_items : Int) -> Bloom {
  let m = if expected_items < 64 { 1024 } else { expected_items * 16 }
  let k = 7
  let bits : Array[Bool] = []
  let mut i = 0
  while i < m {
    bits.push(false)
    i = i + 1
  }
  { bits, m, k, }
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
/// 加入一个键。
pub fn Bloom::add(self : Bloom, key : String) -> Unit {
  let h1 = fnv1a64(key, 14695981039346656037UL)
  let h2 = fnv1a64(key, 1099511628211UL) | 1UL
  let m64 = self.m.to_uint64()
  let mut i = 0
  while i < self.k {
    let idx = ((h1 + i.to_uint64() * h2) % m64).to_int()
    self.bits[idx] = true
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
    if !self.bits[idx] {
      return false
    }
    i = i + 1
  }
  true
}
