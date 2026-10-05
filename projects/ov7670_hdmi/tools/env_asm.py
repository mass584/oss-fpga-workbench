#!/usr/bin/env python3
# ============================================================================
# BME280 表示用マイクロコードのアセンブラ / 命令シミュレータ / 参照実装 / フォント生成
#
#   python3 tools/env_asm.py        (プロジェクトディレクトリで実行)
#     -> rtl/env_prog.v     計算プログラムの ROM (env_calc.v が実行する)
#     -> rtl/env_font.v     5x7 フォント ROM (text_overlay.v)
#     -> sim/env_vectors.vh テストベクタ (バイトイメージと期待する表示文字)
#   生成前に、命令シミュレータの結果をデータシートの式 (参照実装) と突き合わせる。
#
# 計算器 (env_calc.v) の命令: 32bit レジスタ r0..r15 (r15 = 除算の余り)
#   バイト RAM はセンサのレジスタアドレスそのまま (0x88.. 補正係数, 0xD0 ID, 0xF7.. 測定値)
#   LDB rd, addr | mode<<8: mode 0 = 8bit, 1 = 16bit LE 符号なし, 2 = 16bit LE 符号付き,
#                            3 = 20bit ([addr]<<12 | [addr+1]<<4 | [addr+2]>>4, 測定値)
#   文字 RAM は idx = 行 * 16 + 桁 に文字コード (CHARS の番号) を書く
# ============================================================================
import os
import sys

# ---- 文字コードと 5x7 フォント (行ごとに 5bit, MSB が左) ----
FONT = {
    '0': ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    '1': ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    '2': ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    '3': ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
    '4': ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    '5': ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    '6': ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    '7': ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    '8': ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    '9': ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    ' ': ["00000"] * 7,
    '.': ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
    '-': ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    '%': ["11000", "11001", "00010", "00100", "01000", "10011", "00011"],
    'o': ["01100", "10010", "10010", "01100", "00000", "00000", "00000"],   # 度 (°)
    'C': ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    'h': ["10000", "10000", "10110", "11001", "10001", "10001", "10001"],
    'P': ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    'a': ["00000", "00000", "01110", "00001", "01111", "10001", "01111"],
}
CHARS = "0123456789 .-%oChPa"          # 文字コード = この並びの番号
CODE = {c: i for i, c in enumerate(CHARS)}
LINE_W = 9                             # 1 行の文字数
LINES = 3

# ---- 命令 ----
OPS = ["END", "LDI", "LDB", "ADD", "SUB", "MUL", "DIVU", "DIV2", "ANDI", "OR", "SHL", "SRA",
       "SRL", "SEXT", "CLMP", "PUTC", "PUTD", "PUTZ", "BLK", "SGN", "PUTS", "BNZ", "ADDI"]
OP = {n: i for i, n in enumerate(OPS)}

# レジスタ名 (r15 = rem は除算の余り)
REGS = {n: i for i, n in enumerate(
    ["a", "b", "c", "d", "e", "f", "g", "tf", "T", "P", "H", "id", "adc", "k", "hm", "rem"])}

M32 = 0xFFFFFFFF


def u32(x):
    return x & M32


def s32(x):
    x &= M32
    return x - (1 << 32) if x >> 31 else x


# ---- プログラム (ソース) ----
prog = []      # (op, rd, rs, rt, imm) または ("LABEL", name)


def I(op, rd="a", rs="a", rt="a", imm=0):
    prog.append((op, rd, rs, rt, imm))


def label(name):
    prog.append(("LABEL", name))


def ld16(rd, lo, signed=True, tmp=None):
    """rd = バイト [lo+1]:[lo] (リトルエンディアン 16bit)"""
    I("LDB", rd, imm=lo | ((2 if signed else 1) << 8))


def ld20(rd, msb, tmp=None):
    """rd = [msb]<<12 | [msb+1]<<4 | [msb+2]>>4 (20bit の測定値)"""
    I("LDB", rd, imm=msb | (3 << 8))


def putc(line, col, ch):
    I("PUTC", imm=(CODE[ch] << 8) | (line * 16 + col))


def puts_text(line, text):
    assert len(text) == LINE_W
    for i, ch in enumerate(text):
        putc(line, i, ch)


def digits(src, n, regs):
    """src を 10 で n 回割り、下の桁から regs[0], regs[1].. に入れる (k = 10 が前提)"""
    I("ADDI", "a", src, imm=0)
    for i in range(n):
        I("DIVU", "a", "a", "k")
        I("ADDI", regs[i], "rem", imm=0)


def put_digit(line, col, reg, blank=False):
    I("PUTZ" if blank else "PUTD", rs=reg, imm=line * 16 + col)


# ---------------- 正常時 (エントリ 0) ----------------
# 品番の確認: 0x60 = BME280, 0x58 = BMP280 (湿度なし)。それ以外はエラー表示
I("LDB", "id", imm=0xD0)
I("ADDI", "hm", "id", imm=-0x60)           # hm != 0 なら湿度なし
I("ADDI", "b", "id", imm=-0x58)
I("MUL", "a", "hm", "b")
I("BNZ", rs="a", imm="ERR")

# ---- 温度 (データシート 4.2.3 / BME280_compensate_T_int32) ----
ld16("d", 0x88, signed=False)              # d = dig_T1
ld16("e", 0x8A)                            # e = dig_T2
ld16("g", 0x8C)                            # g = dig_T3
ld20("adc", 0xFA)                          # adc_T
I("SRA", "a", "adc", imm=3)
I("SHL", "b", "d", imm=1)
I("SUB", "a", "a", "b")
I("MUL", "a", "a", "e")
I("SRA", "f", "a", imm=11)                 # f = var1
I("SRA", "a", "adc", imm=4)
I("SUB", "a", "a", "d")
I("MUL", "a", "a", "a")
I("SRA", "a", "a", imm=12)
I("MUL", "a", "a", "g")
I("SRA", "a", "a", imm=14)                 # a = var2
I("ADD", "tf", "f", "a")                   # t_fine
I("LDI", "b", imm=5)
I("MUL", "a", "tf", "b")
I("ADDI", "a", "a", imm=128)
I("SRA", "T", "a", imm=8)                  # T [0.01 degC]

# ---- 気圧 (BME280_compensate_P_int32, 結果 [Pa]) ----
I("SRA", "a", "tf", imm=1)
I("ADDI", "f", "a", imm=-64000)            # f = var1
I("SRA", "a", "f", imm=2)
I("MUL", "g", "a", "a")                    # g = (var1>>2)^2
I("SRA", "a", "g", imm=11)
ld16("b", 0x98)                            # dig_P6
I("MUL", "e", "a", "b")                    # e = var2
ld16("b", 0x96)                            # dig_P5
I("MUL", "a", "f", "b")
I("SHL", "a", "a", imm=1)
I("ADD", "e", "e", "a")
I("SRA", "e", "e", imm=2)
ld16("b", 0x94)                            # dig_P4
I("SHL", "b", "b", imm=16)
I("ADD", "e", "e", "b")
I("SRA", "a", "g", imm=13)
ld16("b", 0x92)                            # dig_P3
I("MUL", "a", "a", "b")
I("SRA", "a", "a", imm=3)
ld16("b", 0x90)                            # dig_P2
I("MUL", "b", "b", "f")
I("SRA", "b", "b", imm=1)
I("ADD", "a", "a", "b")
I("SRA", "f", "a", imm=18)
I("ADDI", "a", "f", imm=32768)
ld16("b", 0x8E, signed=False)              # dig_P1
I("MUL", "a", "a", "b")
I("SRA", "f", "a", imm=15)                 # f = var1
ld20("adc", 0xF7)                          # adc_P
I("LDI", "a", imm=1048576)
I("SUB", "a", "a", "adc")
I("SRA", "b", "e", imm=12)
I("SUB", "a", "a", "b")
I("LDI", "b", imm=3125)
I("MUL", "a", "a", "b")
I("DIV2", "P", "a", "f")                   # p (< 0x80000000 なら (p<<1)/var1, それ以外 (p/var1)*2)
I("SRL", "a", "P", imm=3)
I("MUL", "a", "a", "a")
I("SRL", "a", "a", imm=13)
ld16("b", 0x9E)                            # dig_P9
I("MUL", "a", "a", "b")
I("SRA", "f", "a", imm=12)
I("SRL", "a", "P", imm=2)
ld16("b", 0x9C)                            # dig_P8
I("MUL", "a", "a", "b")
I("SRA", "e", "a", imm=13)
I("ADD", "a", "f", "e")
ld16("b", 0x9A)                            # dig_P7
I("ADD", "a", "a", "b")
I("SRA", "a", "a", imm=4)
I("ADD", "P", "P", "a")                    # P [Pa]

# ---- 表示: 温度 "  -12.3oC " (小数点は 4 桁目にそろえる) ----
I("LDI", "k", imm=10)
I("SGN", "a", "T")
I("ADDI", "a", "a", imm=5)
I("DIVU", "a", "a", "k")                   # 0.1 degC 単位に丸める
digits("a", 3, ["b", "c", "d"])
putc(0, 0, ' ')
I("PUTS", imm=0 * 16 + 1)
I("BLK")
put_digit(0, 2, "d", blank=True)
put_digit(0, 3, "c")
putc(0, 4, '.')
put_digit(0, 5, "b")
putc(0, 6, 'o')
putc(0, 7, 'C')
putc(0, 8, ' ')

# ---- 表示: 気圧 " 1005.2hPa" ----
I("ADDI", "a", "P", imm=5)
I("DIVU", "a", "a", "k")                   # 0.1 hPa 単位に丸める
digits("a", 5, ["b", "c", "d", "e", "f"])
I("BLK")
put_digit(2, 0, "f", blank=True)
put_digit(2, 1, "e", blank=True)
put_digit(2, 2, "d", blank=True)
put_digit(2, 3, "c")
putc(2, 4, '.')
put_digit(2, 5, "b")
putc(2, 6, 'h')
putc(2, 7, 'P')
putc(2, 8, 'a')

I("BNZ", rs="hm", imm="NOHUM")

# ---- 湿度 (BME280_compensate_H_int32, 結果 [%RH * 1024]) ----
I("ADDI", "f", "tf", imm=-76800)           # f = v_x1
I("LDB", "a", imm=0xFD)
I("SHL", "a", "a", imm=8)
I("LDB", "b", imm=0xFE)
I("OR", "a", "a", "b")
I("SHL", "a", "a", imm=14)                 # adc_H << 14
I("LDB", "b", imm=0xE4)                    # dig_H4 = (int8)E4 << 4 | E5[3:0]
I("SEXT", "b", "b", imm=8)
I("SHL", "b", "b", imm=4)
I("LDB", "c", imm=0xE5)
I("ANDI", "c", "c", imm=0x0F)
I("OR", "b", "b", "c")
I("SHL", "b", "b", imm=20)
I("SUB", "a", "a", "b")
I("LDB", "b", imm=0xE6)                    # dig_H5 = (int8)E6 << 4 | E5[7:4]
I("SEXT", "b", "b", imm=8)
I("SHL", "b", "b", imm=4)
I("LDB", "c", imm=0xE5)
I("SRL", "c", "c", imm=4)
I("OR", "b", "b", "c")
I("MUL", "b", "b", "f")
I("SUB", "a", "a", "b")
I("ADDI", "a", "a", imm=16384)
I("SRA", "g", "a", imm=15)                 # g = 前半
I("LDB", "b", imm=0xE7)                    # dig_H6 (int8)
I("SEXT", "b", "b", imm=8)
I("MUL", "b", "f", "b")
I("SRA", "b", "b", imm=10)
I("LDB", "c", imm=0xE3)                    # dig_H3 (uint8)
I("MUL", "c", "f", "c")
I("SRA", "c", "c", imm=11)
I("ADDI", "c", "c", imm=32768)
I("MUL", "b", "b", "c")
I("SRA", "b", "b", imm=10)
I("ADDI", "b", "b", imm=2097152)
ld16("c", 0xE1, tmp="d")                   # dig_H2
I("MUL", "b", "b", "c")
I("ADDI", "b", "b", imm=8192)
I("SRA", "b", "b", imm=14)
I("MUL", "f", "g", "b")
I("SRA", "a", "f", imm=15)
I("MUL", "a", "a", "a")
I("SRA", "a", "a", imm=7)
I("LDB", "b", imm=0xA1)                    # dig_H1 (uint8)
I("MUL", "a", "a", "b")
I("SRA", "a", "a", imm=4)
I("SUB", "f", "f", "a")
I("CLMP", "f", "f", imm=419430400)
I("SRA", "H", "f", imm=12)                 # H [%RH * 1024]

# ---- 表示: 湿度 "  45.6%  " ----
I("LDI", "b", imm=10)
I("MUL", "a", "H", "b")
I("ADDI", "a", "a", imm=512)
I("SRL", "a", "a", imm=10)                 # 0.1 % 単位
digits("a", 4, ["b", "c", "d", "e"])
I("BLK")
putc(1, 0, ' ')
put_digit(1, 1, "e", blank=True)
put_digit(1, 2, "d", blank=True)
put_digit(1, 3, "c")
putc(1, 4, '.')
put_digit(1, 5, "b")
putc(1, 6, '%')
putc(1, 7, ' ')
putc(1, 8, ' ')
I("END")

label("NOHUM")                             # BMP280: 湿度なし
puts_text(1, "  --.-%  ")
I("END")

# ---------------- エラー (センサが応答しない / 品番が違う) ----------------
label("ERR")
puts_text(0, "  --.-oC ")
puts_text(1, "  --.-%  ")
puts_text(2, " ---.-hPa")
I("END")


# ---- アセンブル ----
def assemble(src):
    labels, code = {}, []
    for ins in src:
        if ins[0] == "LABEL":
            labels[ins[1]] = len(code)
        else:
            code.append(ins)
    words = []
    for op, rd, rs, rt, imm in code:
        if isinstance(imm, str):
            imm = labels[imm]
        words.append((OP[op], REGS[rd], REGS[rs], REGS[rt], u32(imm)))
    return words, labels


def encode(w):
    op, rd, rs, rt, imm = w
    return (op << 44) | (rd << 40) | (rs << 36) | (rt << 32) | imm


# ---- 命令シミュレータ (env_calc.v と同じ動作) ----
def run(words, mem, entry=0, max_steps=10000):
    r = [0] * 16
    text = [CODE[' ']] * 64
    neg = blank = False
    pc = entry
    for _ in range(max_steps):
        op, rd, rs, rt, imm = words[pc]
        name = OPS[op]
        pc += 1
        a, b = r[rs], r[rt]
        if name == "END":
            return text
        elif name == "LDI":
            r[rd] = imm
        elif name == "LDB":
            ad, mode = imm & 0xFF, (imm >> 8) & 3
            b0, b1, b2 = mem[ad], mem[(ad + 1) & 0xFF], mem[(ad + 2) & 0xFF]
            if mode == 0:
                r[rd] = b0
            elif mode == 3:
                r[rd] = (b0 << 12) | (b1 << 4) | (b2 >> 4)
            else:
                v = b0 | (b1 << 8)
                r[rd] = u32(v - 65536) if mode == 2 and v & 0x8000 else v
        elif name == "ADD":
            r[rd] = u32(a + b)
        elif name == "SUB":
            r[rd] = u32(a - b)
        elif name == "MUL":
            r[rd] = u32(a * b)
        elif name in ("DIVU", "DIV2"):
            if name == "DIVU":
                n, post = a, 0
            else:
                n, post = (u32(a << 1), 0) if a < 0x80000000 else (a, 1)
            if b == 0:
                q, rem = M32, n
            else:
                q, rem = n // b, n % b
            r[rd] = u32(q << post)
            r[15] = rem
        elif name == "ANDI":
            r[rd] = a & imm
        elif name == "OR":
            r[rd] = a | b
        elif name == "SHL":
            r[rd] = u32(a << (imm & 31))
        elif name == "SRA":
            r[rd] = u32(s32(a) >> (imm & 31))
        elif name == "SRL":
            r[rd] = a >> (imm & 31)
        elif name == "SEXT":
            n = imm & 31
            assert n in (8, 16), "SEXT は 8 / 16 ビットのみ (env_calc.v)"
            v = a & ((1 << n) - 1)
            r[rd] = u32(v - (1 << n) if v >> (n - 1) else v)
        elif name == "CLMP":
            v = s32(a)
            r[rd] = 0 if v < 0 else min(v, imm)
        elif name == "PUTC":
            text[imm & 63] = (imm >> 8) & 31
        elif name in ("PUTD", "PUTZ"):
            d = a & 15
            if name == "PUTZ" and blank and d == 0:
                text[imm & 63] = CODE[' ']
            else:
                text[imm & 63] = d
                blank = False
        elif name == "BLK":
            blank = True
        elif name == "SGN":
            v = s32(a)
            neg = v < 0
            r[rd] = u32(-v if neg else v)
        elif name == "PUTS":
            text[imm & 63] = CODE['-'] if neg else CODE[' ']
        elif name == "BNZ":
            if a != 0:
                pc = imm & 0xFF
        elif name == "ADDI":
            r[rd] = u32(a + imm)
        else:
            raise ValueError(name)
    raise RuntimeError("END に到達しない")


def text_lines(text):
    return ["".join(CHARS[text[l * 16 + c]] for c in range(LINE_W)) for l in range(LINES)]


# ---- 参照実装 (データシートの C コードを int32 のまま写したもの) ----
def cal(mem):
    def u16(lo):
        return mem[lo] | (mem[lo + 1] << 8)

    def s16(lo):
        v = u16(lo)
        return v - 65536 if v & 0x8000 else v

    def s8(v):
        return v - 256 if v & 0x80 else v
    c = dict(T1=u16(0x88), T2=s16(0x8A), T3=s16(0x8C), P1=u16(0x8E))
    for i, a in zip(range(2, 10), range(0x90, 0xA0, 2)):
        c[f"P{i}"] = s16(a)
    c.update(H1=mem[0xA1], H2=s16(0xE1), H3=mem[0xE3],
             H4=(s8(mem[0xE4]) * 16) | (mem[0xE5] & 0x0F),
             H5=(s8(mem[0xE6]) * 16) | (mem[0xE5] >> 4), H6=s8(mem[0xE7]))
    return c


def reference(mem):
    c = cal(mem)
    adc_T = (mem[0xFA] << 12) | (mem[0xFB] << 4) | (mem[0xFC] >> 4)
    adc_P = (mem[0xF7] << 12) | (mem[0xF8] << 4) | (mem[0xF9] >> 4)
    adc_H = (mem[0xFD] << 8) | mem[0xFE]
    S = s32
    var1 = S(S(S((adc_T >> 3) - (c["T1"] << 1)) * c["T2"]) >> 11)
    var2 = S(S(S(S(S((adc_T >> 4) - c["T1"]) * S((adc_T >> 4) - c["T1"])) >> 12) * c["T3"]) >> 14)
    t_fine = S(var1 + var2)
    T = S(t_fine * 5 + 128) >> 8
    # 気圧
    var1 = S((t_fine >> 1) - 64000)
    var2 = S(S(S(S(var1 >> 2) * S(var1 >> 2)) >> 11) * c["P6"])
    var2 = S(var2 + S(S(var1 * c["P5"]) << 1))
    var2 = S((var2 >> 2) + S(c["P4"] << 16))
    var1 = S((S(S(c["P3"] * S(S(S(var1 >> 2) * S(var1 >> 2)) >> 13)) >> 3) + S(S(c["P2"] * var1) >> 1)) >> 18)
    var1 = S(S(S(32768 + var1) * c["P1"]) >> 15)
    if var1 == 0:
        P = 0
    else:
        p = u32(u32(u32(1048576 - adc_P) - u32(var2 >> 12)) * 3125)
        p = u32((p << 1) // u32(var1)) if p < 0x80000000 else u32((p // u32(var1)) * 2)
        var1 = S(S(c["P9"] * S(u32((p >> 3) * (p >> 3)) >> 13)) >> 12)
        var2 = S(S(S(p >> 2) * c["P8"]) >> 13)
        P = u32(S(p) + ((var1 + var2 + c["P7"]) >> 4))
    # 湿度
    v = S(t_fine - 76800)
    v = S(S(S(S(S(S(adc_H << 14) - S(c["H4"] << 20)) - S(c["H5"] * v)) + 16384) >> 15)
          * S(S(S(S(S(S(S(S(v * c["H6"]) >> 10) * S(S(S(v * c["H3"]) >> 11) + 32768)) >> 10) + 2097152)
                  * c["H2"]) + 8192) >> 14))
    v = S(v - S(S(S(S(S(v >> 15) * S(v >> 15)) >> 7) * c["H1"]) >> 4))
    v = max(0, min(v, 419430400))
    H = v >> 12
    return T, P, H


def ref_text(mem):
    chip = mem[0xD0]
    if chip not in (0x60, 0x58):
        return ["  --.-oC ", "  --.-%  ", " ---.-hPa"]
    T, P, H = reference(mem)
    t = (abs(T) + 5) // 10
    s = "-" if T < 0 else " "
    tens = str(t // 100 % 10) if t // 100 % 10 else " "
    l0 = " " + s + tens + str(t // 10 % 10) + "." + str(t % 10) + "oC "
    p = (P + 5) // 10
    l2 = f"{p // 10 % 100000:>4d}"[-4:] + "." + str(p % 10) + "hPa"
    if chip == 0x58:
        l1 = "  --.-%  "
    else:
        h = (H * 10 + 512) >> 10
        l1 = " " + f"{h // 10 % 1000:>3d}"[-3:] + "." + str(h % 10) + "%  "
    return [l0, l1, l2]


# ---- テストベクタ ----
def make_mem(chip, cal_bytes, adc_P, adc_T, adc_H, h_bytes):
    mem = [0] * 256
    mem[0xD0] = chip
    for i, b in enumerate(cal_bytes):
        mem[0x88 + i] = b
    for i, b in enumerate(h_bytes):
        mem[0xE1 + i] = b
    mem[0xF7], mem[0xF8], mem[0xF9] = adc_P >> 12, (adc_P >> 4) & 0xFF, (adc_P & 0xF) << 4
    mem[0xFA], mem[0xFB], mem[0xFC] = adc_T >> 12, (adc_T >> 4) & 0xFF, (adc_T & 0xF) << 4
    mem[0xFD], mem[0xFE] = adc_H >> 8, adc_H & 0xFF
    return mem


def le16(*vals):
    out = []
    for v in vals:
        out += [v & 0xFF, (v >> 8) & 0xFF]
    return out


# 実機の BME280 で見られる程度の補正係数
CAL = le16(28485, 26735, 50, 37740, -10620, 3024, 7277, -59, -7, 9900, -10230, 4285) + [0, 75]  # 0x88..0xA1
HCAL = le16(371) + [0, 307 >> 4, (307 & 0xF) | ((50 & 0xF) << 4), 50 >> 4, 30]                 # 0xE1..0xE7

VECTORS = [
    ("BME280 室温",            make_mem(0x60, CAL, 330000, 519888, 28000, HCAL)),
    ("BME280 氷点下",          make_mem(0x60, CAL, 335000, 400000, 20000, HCAL)),
    ("BME280 低気圧 (DIV2 の p>=2^31 側)", make_mem(0x60, CAL, 300000, 530000, 35000, HCAL)),
    ("BME280 乾燥 (湿度 0 に飽和)",  make_mem(0x60, CAL, 330000, 519888, 0, HCAL)),
    ("BMP280 (湿度なし)",      make_mem(0x58, CAL, 330000, 519888, 0x8000, HCAL)),
    ("品番違い (エラー表示)",   make_mem(0x00, CAL, 330000, 519888, 28000, HCAL)),
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    proj = os.path.dirname(here)
    words, labels = assemble(prog)
    assert len(words) <= 256, len(words)

    # 命令シミュレータと参照実装の突き合わせ
    for name, mem in VECTORS:
        got = text_lines(run(words, mem))
        exp = ref_text(mem)
        T, P, H = reference(mem)
        print(f"{name:28s} T={T/100:7.2f}C P={P/100:8.2f}hPa H={H/1024:6.2f}% -> {got}")
        if got != exp:
            sys.exit(f"不一致: {name}: 命令シミュレータ {got} / 参照 {exp}")
    err = text_lines(run(words, VECTORS[0][1], entry=labels["ERR"]))
    assert err == ["  --.-oC ", "  --.-%  ", " ---.-hPa"], err

    gen = "// 自動生成 (tools/env_asm.py)。手で編集しないこと\n"
    with open(os.path.join(proj, "rtl", "env_prog.v"), "w") as f:
        f.write(gen)
        f.write("// 計算プログラム ROM: {op[4:0], rd[3:0], rs[3:0], rt[3:0], imm[31:0]}\n")
        f.write("// 同期読み出し (レイテンシ 1)。LUT に置く (BSRAM に置くと pc -> アドレス入力で\n")
        f.write("// nextpnr のホールド違反が出た。LUT には余裕がある)\n")
        f.write("module env_prog (\n    input  wire        clk,\n    input  wire [7:0]  addr,\n")
        f.write("    output reg  [48:0] q,\n    output wire [7:0]  err_entry      // エラー表示のエントリ\n);\n")
        f.write(f"    assign err_entry = 8'd{labels['ERR']};\n")
        f.write("    (* ram_style = \"logic\" *) reg [48:0] rom [0:255];\n    integer i;\n    initial begin\n")
        f.write("        q = 49'h0;\n        for (i = 0; i < 256; i = i + 1) rom[i] = 49'h0;\n")
        for i, w in enumerate(words):
            f.write(f"        rom[{i}] = 49'h{encode(w):013X};  // {OPS[w[0]]}\n")
        f.write("    end\n    always @(posedge clk) q <= rom[addr];\nendmodule\n")

    with open(os.path.join(proj, "rtl", "env_font.v"), "w") as f:
        f.write(gen)
        f.write("// 5x7 フォント ROM: 文字コード (" + CHARS + " の番号) と行 0..7 -> 5bit (MSB が左)\n")
        f.write("module env_font (\n    input  wire [4:0] code,\n    input  wire [2:0] row,\n")
        f.write("    output reg  [4:0] bits\n);\n    always @* begin\n        case ({code, row})\n")
        for ci, ch in enumerate(CHARS):
            for ri, rowbits in enumerate(FONT[ch]):
                if rowbits != "00000":
                    f.write(f"            8'h{(ci << 3) | ri:02X}: bits = 5'b{rowbits};  // '{ch}'\n")
        f.write("            default: bits = 5'b00000;\n        endcase\n    end\nendmodule\n")

    with open(os.path.join(proj, "sim", "env_vectors.vh"), "w") as f:
        f.write(gen)
        f.write("// テストベクタ: env_vec(n) で vb (バイトイメージ) と vt (期待する文字コード 3 行 x 9) を設定\n")
        f.write(f"localparam integer ENV_NV = {len(VECTORS)};\n")
        f.write("task automatic env_vec(input integer n);\n    integer i;\n    begin\n")
        f.write("        for (i = 0; i < 256; i = i + 1) vb[i] = 8'h00;\n        case (n)\n")
        for n, (name, mem) in enumerate(VECTORS):
            exp = ref_text(mem)
            f.write(f"            {n}: begin  // {name}: {exp}\n")
            for a in range(256):
                if mem[a]:
                    f.write(f"                vb[8'h{a:02X}] = 8'h{mem[a]:02X};\n")
            codes = [CODE[ch] for line in exp for ch in line]
            f.write("                vt = {" + ", ".join(f"5'd{c}" for c in codes) + "};\n")
            f.write("            end\n")
        f.write("            default: ;\n        endcase\n    end\nendtask\n")
        f.write(f'localparam [8*{len(CHARS)}-1:0] ENV_CHARS = "{CHARS}";\n')
    print(f"{len(words)} 命令 (ERR = {labels['ERR']}, NOHUM = {labels['NOHUM']}) -> rtl/env_prog.v, "
          "rtl/env_font.v, sim/env_vectors.vh")


if __name__ == "__main__":
    main()
