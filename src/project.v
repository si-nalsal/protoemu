/*
 * Copyright (c) 2026 Sinalsal
 * SPDX-License-Identifier: Apache-2.0
 *
 * Area probe for the programmable protocol emulator (IHP SG13CMOS5L, 8x4 tiles).
 *
 * This is NOT the final design. It measures what storage costs on this process:
 *   - one IHP RM_IHPSG13_1P_256x16_c2_bm_bist SRAM macro (4096 bits), and
 *   - a 16 x 16 flip-flop memory (256 bits) with the same interface,
 * plus a 16-bit free-running counter. Every storage bit can be written from the
 * inputs and read back on uo_out, so synthesis cannot remove any of it.
 *
 * The SRAM integration (src/sram_bb.v, src/pdn_cfg.tcl, the SRAM section of
 * src/config.json, librelane_plugin_sram_pdn.py, odb_stripes.py, test/sram_model)
 * follows Tiny Tapeout's ttihp-cmos5l-sram-example, which is based on
 * Ken Pettit's CMOS5L SRAM design.
 *
 * One command per clock cycle, sampled on the rising edge of clk:
 *   ui_in[7:6] = 2'b00: read       - the selected memory reads the word at addr
 *                2'b01: address    - address register <= uio_in
 *                2'b10: write low  - low byte of the addressed word <= uio_in
 *                2'b11: write high - high byte of the addressed word <= uio_in
 *   ui_in[5]   = target memory: 0 = SRAM (addr[7:0]), 1 = flop memory (addr[3:0])
 *   ui_in[4]   = uo_out source: 0 = memory read data, 1 = counter
 *   ui_in[0]   = byte select for uo_out (0: low byte, 1: high byte)
 *
 * ui_in[5:4] and ui_in[0] also steer the output multiplexer directly, so
 * uo_out shows the selected source as soon as they change.
 *
 * The inputs are registered, so a command reaches the memories one clock edge
 * after it is sampled. Each memory's read data holds the last word it read;
 * writes don't change it. After a set address command, the word is on uo_out
 * after the third rising edge of clk, counting the one that samples the command.
 */

`default_nettype none

module tt_um_si_nalsal_protoemu (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  localparam CMD_READ = 2'b00;
  localparam CMD_ADDR = 2'b01;

  // ---------------------------------------------------------------------------
  // Input registers: every memory input comes from a flip-flop.
  // ---------------------------------------------------------------------------
  reg  [1:0] cmd_q;     // command
  reg        tgt_q;     // target memory (0 = SRAM, 1 = flops)
  reg  [7:0] data_q;    // data byte
  reg        run_q;     // 0 while in reset: blocks all memory accesses
  reg  [7:0] addr;      // address register

  always @(posedge clk) begin
    run_q  <= rst_n;
    cmd_q  <= rst_n ? ui_in[7:6] : CMD_READ;
    tgt_q  <= ui_in[5];
    data_q <= uio_in;
    if (!rst_n)
      addr <= 8'd0;
    else if (cmd_q == CMD_ADDR)
      addr <= data_q;
  end

  wire write    = cmd_q[1];             // 2'b10 or 2'b11
  wire hi_byte  = cmd_q[0];             // which byte a write changes
  wire read     = (cmd_q == CMD_READ);

  // ---------------------------------------------------------------------------
  // SRAM: IHP RM_IHPSG13_1P_256x16_c2_bm_bist (single port, 256 x 16)
  // The instance name "sram" is referenced by MACROS and PDN_MACRO_CONNECTIONS
  // in src/config.json, so it must not change.
  // ---------------------------------------------------------------------------
  wire        sram_sel = run_q & ~tgt_q;
  wire [15:0] sram_dout;

  RM_IHPSG13_1P_256x16_c2_bm_bist sram (
      .A_CLK      (clk),
      .A_MEN      (sram_sel),
      .A_WEN      (write),
      .A_REN      (~write),
      .A_ADDR     (addr),
      .A_DIN      ({data_q, data_q}),
      .A_DLY      (1'b1),               // must be tied high (see the macro datasheet)
      .A_DOUT     (sram_dout),
      .A_BM       (hi_byte ? 16'hFF00 : 16'h00FF),
      .A_BIST_CLK (1'b0),
      .A_BIST_EN  (1'b0),
      .A_BIST_MEN (1'b0),
      .A_BIST_WEN (1'b0),
      .A_BIST_REN (1'b0),
      .A_BIST_ADDR(8'd0),
      .A_BIST_DIN (16'd0),
      .A_BIST_BM  (16'd0)
  );

  // ---------------------------------------------------------------------------
  // Flop memory: 16 x 16, same interface and read latency as the SRAM.
  // No reset on the array: like the SRAM, its contents are undefined until the
  // host writes them, and a reset on 256 flops would only cost area.
  // ---------------------------------------------------------------------------
  wire        ff_sel = run_q & tgt_q;
  reg  [15:0] ff_mem [0:15];
  reg  [15:0] ff_dout;

  always @(posedge clk) begin
    if (ff_sel && write) begin
      if (hi_byte)
        ff_mem[addr[3:0]][15:8] <= data_q;
      else
        ff_mem[addr[3:0]][7:0]  <= data_q;
    end
    if (ff_sel && read)
      ff_dout <= ff_mem[addr[3:0]];
  end

  // ---------------------------------------------------------------------------
  // 16-bit free-running counter
  // ---------------------------------------------------------------------------
  reg [15:0] counter;

  always @(posedge clk) begin
    if (!rst_n)
      counter <= 16'd0;
    else
      counter <= counter + 16'd1;
  end

  // ---------------------------------------------------------------------------
  // Output multiplexer
  // ---------------------------------------------------------------------------
  wire [15:0] out_word = ui_in[4] ? counter :
                         ui_in[5] ? ff_dout : sram_dout;

  assign uo_out  = ui_in[0] ? out_word[15:8] : out_word[7:0];
  assign uio_out = 8'd0;
  assign uio_oe  = 8'd0;   // all uio pins are inputs (data byte)

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, ui_in[3:1], 1'b0};

endmodule
