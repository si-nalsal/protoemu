# SPDX-FileCopyrightText: © 2026 Sinalsal
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the area probe (src/project.v). The command helpers follow
# Tiny Tapeout's ttihp-cmos5l-sram-example.

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CMD_READ = 0b00
CMD_ADDR = 0b01
CMD_WRITE_LO = 0b10
CMD_WRITE_HI = 0b11

SRAM = 0
FLOPS = 1

SRAM_WORDS = 256
FLOP_WORDS = 16


async def start(dut):
    # 20 ns clock period (50 MHz), as in info.yaml and src/config.json
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)


async def command(dut, cmd, value=0, target=SRAM, byte_sel=0, counter=0):
    dut.ui_in.value = (cmd << 6) | (target << 5) | (counter << 4) | byte_sel
    dut.uio_in.value = value
    await ClockCycles(dut.clk, 1)


async def write_word(dut, addr, word, target=SRAM):
    await command(dut, CMD_ADDR, addr, target)
    await command(dut, CMD_WRITE_LO, word & 0xFF, target)
    await command(dut, CMD_WRITE_HI, word >> 8, target)


async def read_word(dut, addr, target=SRAM):
    await command(dut, CMD_ADDR, addr, target)
    # The word is on uo_out after the third rising edge of clk, counting the one
    # that samples the set address command (see project.v). cocotb sees the values
    # from before the edge it just awaited, so wait for one edge more.
    for _ in range(3):
        await command(dut, CMD_READ, target=target)
    lo = dut.uo_out.value.to_unsigned()
    await command(dut, CMD_READ, target=target, byte_sel=1)
    hi = dut.uo_out.value.to_unsigned()
    return (hi << 8) | lo


@cocotb.test()
async def test_sram_all_addresses(dut):
    await start(dut)
    # A unique word per address, so that a stuck or swapped address bit shows
    random.seed(1)
    words = random.sample(range(0x10000), SRAM_WORDS)
    for addr, word in enumerate(words):
        await write_word(dut, addr, word, SRAM)
    for addr, word in enumerate(words):
        got = await read_word(dut, addr, SRAM)
        assert got == word, f"SRAM {addr:#04x}: read {got:#06x}, expected {word:#06x}"


@cocotb.test()
async def test_flops_all_addresses(dut):
    await start(dut)
    random.seed(2)
    words = random.sample(range(0x10000), FLOP_WORDS)
    for addr, word in enumerate(words):
        await write_word(dut, addr, word, FLOPS)
    for addr, word in enumerate(words):
        got = await read_word(dut, addr, FLOPS)
        assert got == word, f"flops {addr:#04x}: read {got:#06x}, expected {word:#06x}"


@cocotb.test()
async def test_byte_writes(dut):
    await start(dut)
    for target in (SRAM, FLOPS):
        await write_word(dut, 0x05, 0xABCD, target)
        await command(dut, CMD_ADDR, 0x05, target)
        await command(dut, CMD_WRITE_HI, 0x12, target)
        assert await read_word(dut, 0x05, target) == 0x12CD
        await command(dut, CMD_ADDR, 0x05, target)
        await command(dut, CMD_WRITE_LO, 0x34, target)
        assert await read_word(dut, 0x05, target) == 0x1234


@cocotb.test()
async def test_memories_are_independent(dut):
    await start(dut)
    # Same address in both memories: a write to one must not touch the other
    await write_word(dut, 0x03, 0x1111, SRAM)
    await write_word(dut, 0x03, 0x2222, FLOPS)
    assert await read_word(dut, 0x03, SRAM) == 0x1111
    assert await read_word(dut, 0x03, FLOPS) == 0x2222
    await write_word(dut, 0x03, 0x3333, SRAM)
    assert await read_word(dut, 0x03, FLOPS) == 0x2222
    assert await read_word(dut, 0x03, SRAM) == 0x3333


@cocotb.test()
async def test_flops_use_low_address_bits(dut):
    await start(dut)
    # The flop memory has 16 words: address 0x13 must alias address 0x03
    await write_word(dut, 0x13, 0xBEEF, FLOPS)
    assert await read_word(dut, 0x03, FLOPS) == 0xBEEF


@cocotb.test()
async def test_counter(dut):
    await start(dut)
    # Low byte of the counter on uo_out: it must advance by one per clock
    await command(dut, CMD_READ, counter=1)
    first = dut.uo_out.value.to_unsigned()
    await ClockCycles(dut.clk, 10)
    second = dut.uo_out.value.to_unsigned()
    assert (second - first) % 256 == 10, f"counter went {first} -> {second}"


@cocotb.test()
async def test_writes_ignored_during_reset(dut):
    await start(dut)
    for target in (SRAM, FLOPS):
        await write_word(dut, 0x00, 0x0123, target)
        await write_word(dut, 0x0A, 0x5678, target)
        await command(dut, CMD_ADDR, 0x0A, target)
        dut.rst_n.value = 0
        await command(dut, CMD_WRITE_LO, 0xFF, target)
        await command(dut, CMD_WRITE_HI, 0xFF, target)
        dut.rst_n.value = 1
        await command(dut, CMD_READ, target=target)
        assert await read_word(dut, 0x0A, target) == 0x5678
        # The address register resets to 0, so an ungated write would land there
        assert await read_word(dut, 0x00, target) == 0x0123
