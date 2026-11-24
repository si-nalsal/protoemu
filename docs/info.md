<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

Work in progress towards a programmable protocol emulator. This version is an area probe: it measures what storage costs on IHP SG13CMOS5L before the real core is designed.

It contains three blocks behind one command interface:

- an IHP `RM_IHPSG13_1P_256x16_c2_bm_bist` SRAM macro (256 words x 16 bits),
- a 16 x 16 flip-flop memory with the same interface,
- a 16-bit free-running counter.

One command is sampled on each rising edge of `clk`:

| `ui_in[7:6]` | Command    | Effect                                              |
| ------------ | ---------- | --------------------------------------------------- |
| `00`         | read       | the selected memory reads the word at the address   |
| `01`         | address    | address register = `uio_in`                         |
| `10`         | write low  | low byte of the addressed word = `uio_in`           |
| `11`         | write high | high byte of the addressed word = `uio_in`          |

- `ui_in[5]` selects the memory: 0 = SRAM (address bits 7:0), 1 = flip-flop memory (address bits 3:0).
- `ui_in[4]` selects what `uo_out` shows: 0 = the last word the selected memory read, 1 = the counter.
- `ui_in[0]` selects the byte on `uo_out`: 0 = low byte, 1 = high byte.

The SRAM integration follows Tiny Tapeout's `ttihp-cmos5l-sram-example`, which is based on Ken Pettit's CMOS5L SRAM design.

## How to test

To write a 16-bit word: send the address command, then write low, then write high. To read it back: send the address command, then three read commands, and sample `uo_out`; set `ui_in[0]` to 1 for the high byte. `ui_in[5]` must stay the same for the whole sequence.

The cocotb tests in `test/test.py` write and read back every SRAM and flip-flop address, check byte writes, check that the two memories don't affect each other, and check the counter.

## External hardware

None.
