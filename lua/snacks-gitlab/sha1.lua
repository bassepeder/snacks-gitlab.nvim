--- Minimal SHA-1 (needed for GitLab diff `line_code`s).
--- Uses LuaJIT's `bit` library, which Neovim always ships with.
local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rol, tobit = bit.rol, bit.tobit

---@param s string
---@return string hex digest
return function(s)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local len = #s
  -- padding: 0x80, zeros, then the 64-bit big-endian bit length
  s = s .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  local hi, lo = math.floor(bits / 0x100000000), bits % 0x100000000
  s = s
    .. string.char(
      math.floor(hi / 0x1000000) % 256,
      math.floor(hi / 0x10000) % 256,
      math.floor(hi / 0x100) % 256,
      hi % 256,
      math.floor(lo / 0x1000000) % 256,
      math.floor(lo / 0x10000) % 256,
      math.floor(lo / 0x100) % 256,
      lo % 256
    )

  local w = {}
  for chunk = 1, #s, 64 do
    for i = 0, 15 do
      local a, b, c, d = s:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = tobit(a * 0x1000000 + b * 0x10000 + c * 0x100 + d)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      local temp = tobit(rol(a, 5) + f + e + k + w[i])
      e, d, c, b, a = d, c, rol(b, 30), a, temp
    end
    h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
  end
  return bit.tohex(h0) .. bit.tohex(h1) .. bit.tohex(h2) .. bit.tohex(h3) .. bit.tohex(h4)
end
