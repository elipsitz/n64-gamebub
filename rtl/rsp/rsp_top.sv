// rsp_top: Mirlo's RSP. The N64's Reality Signal Processor as software sees
// it -- the scalar unit (rsp_su), the vector unit (rsp_vu), IMEM and DMEM
// (4 KiB each), COP0's registers and the DMA engine -- so a game's own
// graphics and audio microcode runs on it. The contract is the reference
// model, sim/rsp/rsp.c.
//
// Memory holds whole words, as the SoC's SDRAM does (a big-endian word's
// first byte in [31:24]). DMEM is 16 bytes wide, as the N64's: an access
// takes the 16 bytes from addr's word on, so any 1 to 4 bytes at any byte
// address are one cycle (the RSP's loads and stores need no alignment), and
// so is every vector load and store but LTV / STV.
//
// The host (the game CPU) reaches the SP registers through h_*:
//   0 SP_MEM_ADDR  1 SP_DRAM_ADDR  2 SP_RD_LEN  3 SP_WR_LEN  4 SP_STATUS
//   5 SP_DMA_FULL  6 SP_DMA_BUSY   7 SP_SEMAPHORE            8 SP_PC
// with the N64's meanings (a write to 2 or 3 starts a DMA; SP_STATUS's write
// bits set and clear halt, broke, the interrupt, the signals). It loads the
// memories by DMA, as libultra does.
//
// The DMA registers are double: a write while a DMA runs goes to the next
// one's (SP_MEM_ADDR, SP_DRAM_ADDR; RD_LEN / WR_LEN queue it: SP_DMA_FULL is
// set, it starts when the running one is done, and a write while FULL replaces it),
// the reads give the running one's, as on the console. The microcode's own
// DMA is queued the same way and runs while the microcode goes on, as the
// console's: it waits on SP_DMA_BUSY / SP_DMA_FULL itself.
// A DMA into or out of DMEM while the microcode runs shares DMEM's port
// with it: the DMA has it (a beat of a transfer in; the whole transfer out) and the
// scalar and vector units' loads and stores wait (m_stall) instead of being lost.
// SP_SEMAPHORE is taken by a read of the host's too (h_rd), as the microcode's.
//
// The RDP's side (DPC) is outside: the microcode's writes to DPC_START,
// DPC_END and DPC_STATUS come out as strobes, DPC_CURRENT and DPC_STATUS as
// it reads them come in.
`default_nettype none

module rsp_top #(
    parameter int LANES = 4,
    parameter bit MULW = 0,                 // (4 lanes) the multiplies on eight
    /* verilator lint_off UNUSEDPARAM */
    parameter     DIV_ROM = "rsp_div_rom.hex"
    /* verilator lint_on UNUSEDPARAM */
) (
    input  wire         clk,
    input  wire         rst,

    // the host's register port (one cycle; reads combinational)
    input  wire         h_we,
    input  wire  [3:0]  h_addr,
    input  wire  [31:0] h_wdata,
    output logic [31:0] h_rdata,
    input  wire         h_rd,               // the host reads a register this cycle (SP_SEMAPHORE is taken by it)
    output logic        h_ready,            // a write is taken (not while the microcode writes a register itself)
    output logic        irq,                // SP interrupt (BREAK with intr-on-break, or set by SP_STATUS)

    // RDRAM (the SoC's SDRAM, a port of its arbiter): word requests taken
    // with r_ready, a read's word back later with r_rvalid, in order
    output logic        r_valid,
    output logic        r_we,
    output logic [23:2] r_addr,
    output logic [31:0] r_wdata,
    input  wire         r_ready,
    input  wire         r_rvalid,
    input  wire  [31:0] r_rdata,

    // the RDP's registers
    output logic        dpc_start_we,       // DPC_START written (dpc_wdata)
    output logic        dpc_end_we,         // DPC_END written
    output logic        dpc_status_we,      // DPC_STATUS written (its set / clear bits)
    output logic [31:0] dpc_wdata,
    input  wire  [31:0] dpc_start,
    input  wire  [31:0] dpc_end,
    input  wire  [31:0] dpc_current,
    input  wire  [31:0] dpc_status,
    // the RDP's reads of DMEM (XBUS: its commands taken from DMEM, not
    // RDRAM): a word, the cycle after its address
    input  wire  [9:0]  dx_addr,
    output logic [31:0] dx_data,

    output logic        halted,
    output logic        unimpl,             // an instruction the vector unit does not implement ran

    // (simulation) the instructions as they leave E, the register writes
    output logic        tr_e,
    output logic [11:0] tr_e_pc,
    output logic        tr_e2,              // ... and the next one with it (a pair: tr_e_pc + 4)
    output logic        tr_e_we,
    output logic [4:0]  tr_e_wr,
    output logic        tr_we,
    output logic [4:0]  tr_wr,
    output logic [31:0] tr_val,
    output logic        tr_mw,              // E waits for DMEM's port, which the DMA has
    output logic [3:0]  tr_v,               // vector-unit instructions whose effects are all in with this cycle
    output logic        tr_vp               // ... the registers' only: the accumulator and flags are a later one's already
);

// ---------------------------------------------------------------- units --
logic        su_run, su_brk, su_idle, pc_load;
logic [11:0] pc_next;
logic [9:0]  i_addr;
logic [31:0] i_data, i_data2;
logic        i2_ok;
logic        sm_valid, sm_we;       logic [11:0] sm_addr; logic [1:0] sm_n; logic [31:0] sm_wdata;
logic        vm_valid, vm_we;       logic [11:0] vm_addr; logic [15:0] vm_be; logic [127:0] vm_wdata; logic [3:0] vm_rot;
logic [31:0] m_rdata;
logic [127:0] m_rdata16;
logic        c_valid, c_done;
logic [31:0] c_ins, c_a, c_b, c_res, c_lins;
logic        c_pr;
logic [4:0]  c_ra_n, c_rb_n, c_rd_n, c_rd;
logic [31:0] v_res_l;
logic        dm_valid /* verilator public_flat_rd */, dm_we;       logic [11:0] dm_addr; logic [31:0] dm_wdata;   // the DMA's (whole words): see the DMEM
logic        tr_e_mem;

rsp_su #(.LPAIR(LANES == 8)) su (.clk, .rst, .run(su_run), .pc_load, .pc_in(h_wdata[11:0]), .pc_next, .brk(su_brk), .idle(su_idle),
    .i_addr, .i_data, .i_data2, .i2_ok,
    .m_valid(sm_valid), .m_we(sm_we), .m_addr(sm_addr), .m_n(sm_n), .m_wdata(sm_wdata), .m_rdata, .m_stall(dm_valid),
    .c_valid, .c_ins, .c_a, .c_b, .c_pr, .c_lins, .c_done, .c_res, .c_res_l(v_res_l), .c_ra_n, .c_rb_n, .c_rd_n, .c_rd,
    .tr_e, .tr_e_pc, .tr_e2, .tr_e_mem, .tr_e_we, .tr_e_wr, .tr_we, .tr_wr, .tr_val);

// (what is not a computation -- COP0, a vector load, store or move -- is never a pair's computation: E's own instruction,
// c_lins, which c_ins only adds a select to; c_pr: a pair, its computation on c_ins)
wire         is_cop0 = c_lins[31:26] == 6'h10;
wire         l_vu    = c_lins[31:26] == 6'h32 || c_lins[31:26] == 6'h3A || (c_lins[31:26] == 6'h12 && !c_lins[25]);   // the vector unit's
logic        v_done;
logic [31:0] v_res;
logic [9:0]  rom_addr;
logic [15:0] rom_q;
rsp_vu #(.LANES(LANES), .MULW(MULW)) vu (.clk, .rst, .valid(c_valid && (c_pr || !is_cop0)), .ins(c_ins), .a(c_a), .b(c_b),
    .l_valid(c_valid && c_pr && l_vu), .l_ins(c_lins), .ra_n(c_ra_n), .rb_n(c_rb_n), .rd_n(c_rd_n), .rd(c_rd), .done(v_done), .res(v_res), .res_l(v_res_l),
    .m_valid(vm_valid), .m_we(vm_we), .m_addr(vm_addr), .m_be(vm_be), .m_wdata(vm_wdata), .m_rot(vm_rot), .m_rdata(m_rdata16), .m_stall(dm_valid),
    .rom_addr, .rom_q, .unimpl, .commit(tr_v), .commit_part(tr_vp));

// the reciprocal ROM: 512 reciprocals, 512 inverse square roots (rtl/rsp/rsp_div_rom.sv)
rsp_div_rom u_div_rom (.clk(clk), .addr(rom_addr), .q(rom_q));

// ----------------------------------------------------------------- IMEM --
// two ports: the fetch's, and the DMA's -- its writes (a transfer in) and
// its reads (a transfer out of IMEM: a word a cycle). With no DMA of IMEM's
// the second reads the word after the fetch's, for the scalar unit's pairs
(* ram_style = "block" *) logic [31:0] imem [0:1023];
logic        iw_we;
logic [9:0]  iw_addr;
logic [31:0] iw_data, ia_q;
logic        im_dma;                  // (below: a DMA of IMEM runs)
wire  [9:0]  ib_addr = im_dma ? iw_addr : i_addr + 10'd1;    // (one address for the port: a write is a DMA's, im_dma)
always_ff @(posedge clk) begin
    if (iw_we) begin imem[ib_addr] <= iw_data; ia_q <= iw_data; end
    else ia_q <= imem[ib_addr];
end
always_ff @(posedge clk) i2_ok <= !rst && !im_dma && !iw_we;
always_ff @(posedge clk) i_data <= imem[i_addr];
assign i_data2 = ia_q;

// ----------------------------------------------------------------- DMEM --
// one access a cycle: the DMA engine's, the vector unit's or the scalar
// unit's. DMEM is 16 bytes wide (rsp_dpram: four banks, a word of each line
// in each), so an access takes the 16 bytes from x_addr's word on -- what the
// RSP's vector loads and stores need, each in one cycle: what they move lies
// in those 16 bytes. Read data comes back rotated by x_rot bytes (byte m of
// m_rdata16 is the one at DMEM address mod 16 = m + x_rot), so the vector
// unit has its register's bytes in place and the scalar unit its 1 to 4
// bytes in the top word; writes go by the byte's address mod 16 (x_be16,
// x_wd: byte b in [127 - 8b -: 8]).
// the instruction in E is the vector unit's load or store (a computation's, alone or in a pair, does not use DMEM)
wire         vu_own = c_valid && (c_lins[31:26] == 6'h32 || c_lins[31:26] == 6'h3A);
logic        x_valid, x_we;
logic [11:0] x_addr;
logic [15:0] x_be16;
logic [127:0] x_wd;
logic [3:0]  x_rot_n;
// the scalar unit's bytes: m_n + 1 from the address on; its word (and the
// DMA's) goes to all four banks rotated to the address, the enables pick
wire  [3:0]  sa = sm_addr[3:0];
wire  [31:0] s_rw = {sm_wdata, sm_wdata} >> {sa[1:0], 3'b000};
logic [15:0] s_be;
always_comb
    for (int b = 0; b < 16; b++) s_be[b] = 4'(4'(b) - sa) <= {2'd0, sm_n};
// (the DMA's word and the scalar unit's both go to all four banks: chosen as a word, then against the vector unit's 16 bytes)
wire  [31:0] w_wd = dm_valid ? dm_wdata : s_rw;
always_comb begin
    if (dm_valid)    begin x_valid = 1'b1; x_we = dm_we; x_addr = dm_addr; x_be16 = 16'h000F << {dm_addr[3:2], 2'b00};
                           x_rot_n = dm_addr[3:0]; end
    else if (vu_own) begin x_valid = vm_valid; x_we = vm_we; x_addr = vm_addr; x_be16 = vm_be;
                           x_rot_n = vm_rot; end
    else             begin x_valid = sm_valid; x_we = sm_we; x_addr = sm_addr; x_be16 = s_be;
                           x_rot_n = sa; end
    x_wd = (dm_valid || !vu_own) ? {4{w_wd}} : vm_wdata;
end
// (x_be16 is in address order, bit b the byte at address mod 16 = b; bank k
// takes x_addr's row, or the next one for the words before x_addr's in its line)
wire  [9:0]  x_wa  = x_addr[11:2];
wire  [7:0]  x_wa1 = x_wa[9:2] + 8'd1;
logic [31:0] x_row;
always_comb
    for (int k = 0; k < 4; k++) x_row[8 * k +: 8] = (2'(k) < x_wa[1:0]) ? x_wa1 : x_wa[9:2];
logic [127:0] q16;
logic [3:0]  x_rot;
rsp_dpram dmem (.clk, .a_row(x_row), .a_we((x_valid && x_we) ? x_be16 : 16'd0), .a_dat_w(x_wd), .a_dat_r(q16),
    .b_adr(dx_addr), .b_dat_r(dx_data));
always_ff @(posedge clk) x_rot <= x_rot_n;
// byte m of the result is byte (m + x_rot) mod 16 of the line: by words, then bytes
logic [127:0] q_w;
(* keep *) logic [127:0] x_rd;
always_comb begin
    for (int m = 0; m < 16; m++) q_w[127 - 8 * m -: 8] = q16[127 - 8 * ((m + 4 * int'(x_rot[3:2])) & 15) -: 8];
    for (int m = 0; m < 16; m++) x_rd[127 - 8 * m -: 8] = q_w[127 - 8 * ((m + int'(x_rot[1:0])) & 15) -: 8];
end
assign m_rdata   = x_rd[127:96];
assign m_rdata16 = x_rd;

// ------------------------------------------------------------ registers --
logic        st_halt, st_broke, st_sstep, st_intbrk;
logic [7:0]  st_sig;
logic        sem;
logic [12:3] sp_addr, sp_addr_w;      // [12] IMEM; as it runs (what a read gives), and as last written (where a DMA starts)
logic [23:3] ram_addr, ram_addr_w;
logic [11:3] d_skip;
logic [31:0] status;
logic        dma_busy;                // a DMA runs
logic        p_full;                  // ... and one is queued behind it (SP_DMA_FULL)
wire         dma_bf = dma_busy || p_full;
assign status = {17'd0, st_sig, st_intbrk, st_sstep, 1'b0, p_full, dma_bf, st_broke, st_halt};
assign halted = st_halt;
assign su_run = !st_halt;

// SP_RD_LEN / SP_WR_LEN as they read: of the running transfer, the rows left less one and the bytes left in the row,
// less 8 (counted down as the words go); after one, a count of 0 and a length of 0xFF8; 0 after reset
logic [7:0]  rd_cnt;
logic [11:3] rd_len;
logic        dma_any;                 // a transfer has run
function automatic logic [31:0] cop0_rd(input logic [3:0] r);
    unique case (r)
    4'd0:  return {19'd0, sp_addr, 3'd0};
    4'd1:  return {8'd0, ram_addr, 3'd0};
    4'd2, 4'd3: return {d_skip, 3'd0, rd_cnt, rd_len, 3'd0};   // the running transfer's skip, rows and row bytes left
    4'd4:  return status;
    4'd5:  return {31'd0, p_full};
    4'd6:  return {31'd0, dma_bf};          // (games check for busy right after starting)
    4'd7:  return {31'd0, sem};
    4'd8:  return dpc_start;
    4'd9:  return dpc_end;
    4'd10: return dpc_current;
    4'd11: return dpc_status;
    default: return 32'd0;
    endcase
endfunction

// COP0, from the scalar unit's E stage (a pair's: in the cycle the vector unit takes its computation)
wire         mfc0 = c_valid && c_done && is_cop0 && c_lins[25:21] == 5'd0;
wire         mtc0 = c_valid && c_done && is_cop0 && c_lins[25:21] == 5'd4;
wire  [3:0]  c0r  = c_lins[14:11];
wire         mt_dma = mtc0 && (c0r == 4'd2 || c0r == 4'd3);

// ------------------------------------------------------------------ DMA --
// rows of (len + 1) bytes, in words; `skip` bytes between rows in RDRAM. A
// write of SP_RD_LEN / SP_WR_LEN, the microcode's MTC0 or the host's, returns
// at once: the transfer runs behind it, and the writer polls SP_DMA_BUSY /
// SP_DMA_FULL (SP_STATUS) for its end.
//   in (RDRAM -> SP): a read request a cycle, each word written to DMEM /
//       IMEM as it comes back
//   out (DMEM -> RDRAM): DMEM is read 8 bytes at a time into a FIFO of two
//       pairs (pf), ahead of the pair being written, so a write request goes
//       out every cycle the memory takes one; DMEM's port is the DMA's only
//       in the cycles of those reads (one in two at most), and the
//       microcode's loads and stores go on in the others
//   out of IMEM: the pair's two words one after the other on IMEM's second
//       port (iq), so a pair every three cycles. Only a boot microcode's
//       check of the console does it (a CIC-6105 game's: eight bytes).
typedef enum logic [2:0] { D_IDLE, D_IN, D_OUT, D_END } dst_t;
dst_t        ds;
logic        d_half, q_half;          // the second word of the 8 bytes: in SP memory, in RDRAM
logic [9:0]  d_words;                 // requests left in the row, less one
logic [9:0]  d_row;                   // a row's words, less one
logic [7:0]  d_rows;                  // rows left, less one
logic        q_done;                  // every request is out
logic [9:0]  g_words;                 // words still to move in the row, less one
logic [7:0]  g_rows;                  // rows still to move, less one
wire         d_last = g_words == 10'd0 && g_rows == 8'd0;   // the word being moved is the last
// (counted as the requests are, by rows: the words in all, rows times a
// row's, took a multiplier from the length just written -- the design's
// longest path)
logic [63:0] ob;                      // out: the pair being sent
logic [1:0]  ob_n;                    // its words still to send
logic [8:0]  np;                      // the pair SP memory is asked for next
logic [63:0] pf [2];                  // out of DMEM: the pairs read ahead, a FIFO (pf_h its head, pf_n how many)
logic        pf_h, pf_rd;             // ... and a read went out last cycle (its pair on m_rdata16 now)
logic [1:0]  pf_n;
logic [1:0]  iq;                      // (out of IMEM) the pair's words read: 2, both
logic [31:0] ih_q;                    // ... the first
wire         d_im    = sp_addr[12];   // the transfer is IMEM's
assign im_dma = ds != D_IDLE && d_im;
wire         p_ok    = d_im ? iq == 2'd2 : pf_n != 2'd0;
// RD_LEN / WR_LEN (the microcode's or the host's) is taken into the pending registers (p_*: the length, count and
// skip, which transfer); the DMA starts from them when the running one is done -- the next cycle on an idle engine
logic [31:0] p_len;                   // the pending DMA's length word
logic        p_rd0;                   // ... and it is a read (RDRAM -> SP)
wire         len_w     = mt_dma || (h_we && !mtc0 && (h_addr == 4'd2 || h_addr == 4'd3));
wire         d_start_p = p_full && ds == D_IDLE;
wire  [31:0] d_len   = p_len;
wire         d_rd0   = p_rd0;
wire  [9:0]  sp_word = {sp_addr[11:3], d_half};
assign dma_busy = ds != D_IDLE;
assign rd_cnt   = ds == D_IDLE ? 8'd0 : g_rows;
assign rd_len   = ds == D_IDLE ? (dma_any ? 9'h1FF : 9'h000) : g_words[9:1] - 9'd1 + {8'd0, g_words[0]};

assign r_valid  = (ds == D_IN && !q_done) || (ds == D_OUT && ob_n != 2'd0);
assign r_we     = ds == D_OUT;
assign r_addr   = {ram_addr, q_half};
assign r_wdata  = ob_n == 2'd2 ? ob[63:32] : ob[31:0];
wire         r_go    = r_valid && r_ready;                 // a request taken
wire         o_sent  = ds == D_OUT && r_go;                // out: a word written
wire         o_load  = ds == D_OUT && p_ok && (ob_n == 2'd0 || (ob_n == 2'd1 && r_go));
// a word back is written into SP memory the cycle after (wq_*): the units that use DMEM's port are told one cycle
// ahead, from a register (m_stall = dm_valid), and wait for the beat
logic        wq_v;
logic [31:0] wq_d;
always_ff @(posedge clk) begin
    wq_v <= !rst && ds == D_IN && r_rvalid;
    wq_d <= r_rdata;
end
wire         sp_wr   = wq_v;                               // a word is written into SP memory
// SP memory: DMEM through the access above, IMEM through its second port
// (IMEM is only ever written by a DMA)
wire         dm_rd   = ds == D_OUT && !d_im && 2'(pf_n + 2'(pf_rd)) < 2'd2;   // out of DMEM: a pair read (from registers: m_stall's)
assign dm_valid = (sp_wr && !d_im) || dm_rd;
assign tr_mw    = dm_valid && tr_e_mem;
assign dm_we    = sp_wr;
assign dm_addr  = ds == D_OUT ? {np, 3'b000} : {sp_word, 2'b00};
assign dm_wdata = wq_d;
assign iw_we    = sp_wr && sp_addr[12];
assign iw_addr  = ds == D_OUT ? {np, iq != 2'd0} : sp_word;
assign iw_data  = wq_d;

assign c_res  = is_cop0 ? cop0_rd(c0r) : v_res;
assign c_done = (c_pr || !is_cop0) ? v_done : 1'b1;

// one writer of the SP registers a cycle: the microcode (MTC0) first, the
// host when it is not there (h_ready)
assign h_ready = !mtc0;
wire         w_en   = (mtc0 && !mt_dma) || (h_we && h_ready);
wire  [3:0]  w_reg  = mtc0 ? c0r : h_addr;
wire  [31:0] w_data = mtc0 ? c_b : h_wdata;
assign pc_load = h_we && h_ready && h_addr == 4'd8 && st_halt;
assign dpc_start_we  = mtc0 && c0r == 4'd8;
assign dpc_end_we    = mtc0 && c0r == 4'd9;
assign dpc_status_we = mtc0 && c0r == 4'd11;
assign dpc_wdata = c_b;
// (the host's reads: SP_PC, or one of the eight SP registers -- the SoC maps no other word of the window than these to h_addr
// 0 to 8; the microcode alone reads the DPC registers)
assign h_rdata = h_addr[3] ? {20'd0, pc_next} : cop0_rd({1'b0, h_addr[2:0]});

always_ff @(posedge clk) begin
    if (rst) begin
        st_halt <= 1'b1; st_broke <= 1'b0; st_sstep <= 1'b0; st_intbrk <= 1'b0; st_sig <= 8'd0;
        p_full <= 1'b0; p_len <= '0; p_rd0 <= 1'b0;
        sem <= 1'b0; irq <= 1'b0; sp_addr <= '0; ram_addr <= '0; sp_addr_w <= '0; ram_addr_w <= '0; d_skip <= '0;
        ds <= D_IDLE; d_half <= 1'b0; q_half <= 1'b0; q_done <= 1'b0; dma_any <= 1'b0;
    end else begin
        // ---- register writes
        if (w_en) unique case (w_reg)
        // (while a DMA runs or is queued the write is the next one's: the running one's pointers go on, and are what a read gives)
        4'd0: begin if (!dma_bf) sp_addr <= w_data[12:3]; sp_addr_w <= w_data[12:3]; end
        4'd1: begin if (!dma_bf) ram_addr <= w_data[23:3]; ram_addr_w <= w_data[23:3]; end
        4'd4: begin
            // a clear / set pair: one of them alone acts, both together leave the bit
            if (w_data[1:0] == 2'b01) st_halt <= 1'b0;
            if (w_data[1:0] == 2'b10) st_halt <= 1'b1;
            if (w_data[2])  st_broke <= 1'b0;
            if (w_data[4:3] == 2'b01) irq <= 1'b0;
            if (w_data[4:3] == 2'b10) irq <= 1'b1;
            if (w_data[6:5] == 2'b01) st_sstep <= 1'b0;
            if (w_data[6:5] == 2'b10) st_sstep <= 1'b1;
            if (w_data[8:7] == 2'b01) st_intbrk <= 1'b0;
            if (w_data[8:7] == 2'b10) st_intbrk <= 1'b1;
            for (int i = 0; i < 8; i++) begin
                if (w_data[9 + 2 * i +: 2] == 2'b01) st_sig[i] <= 1'b0;
                if (w_data[9 + 2 * i +: 2] == 2'b10) st_sig[i] <= 1'b1;
            end
        end
        4'd7: sem <= 1'b0;
        default: ;
        endcase
        if ((mfc0 && c0r == 4'd7) || (h_rd && h_addr == 4'd7)) sem <= 1'b1;   // the semaphore: read (the microcode's or the host's), then taken
        // single step: halted again as an instruction (a slot) leaves E
        if (st_sstep && tr_e) st_halt <= 1'b1;
        if (su_brk) begin
            st_halt <= 1'b1; st_broke <= 1'b1;
            if (st_intbrk) irq <= 1'b1;
        end

        // ---- the DMA
        // the RDRAM pointer: a word on with each request taken, the skip at a row's end (not after the last)
        if (r_go) begin
            q_half <= !q_half;
            if (q_half) ram_addr <= ram_addr + 21'd1 + ((d_words == 10'd0 && d_rows != 8'd0) ? {12'd0, d_skip} : 21'd0);
            if (d_words == 10'd0) begin
                d_words <= d_row; d_rows <= d_rows - 8'd1;
                if (d_rows == 8'd0) q_done <= 1'b1;
            end else d_words <= d_words - 10'd1;
        end
        // the SP pointer: a word on with each word moved (it wraps inside its 4 KiB)
        if (sp_wr || o_sent) begin
            d_half <= !d_half;
            if (d_half) sp_addr[11:3] <= sp_addr[11:3] + 9'd1;
            if (g_words == 10'd0) begin g_words <= d_row; g_rows <= g_rows - 8'd1; end
            else g_words <= g_words - 10'd1;
        end
        // a LEN write: pending (a second one before the first starts replaces it); it leaves with its start
        if (d_start_p) p_full <= 1'b0;
        if (len_w) begin p_len <= w_data; p_rd0 <= w_reg == 4'd2; p_full <= 1'b1; end
        unique case (ds)
        D_IDLE: if (d_start_p) begin
            d_row   <= {d_len[11:3], 1'b1};
            d_words <= {d_len[11:3], 1'b1};
            d_rows  <= d_len[19:12];
            d_skip  <= d_len[31:23];
            g_words <= {d_len[11:3], 1'b1};
            g_rows  <= d_len[19:12];
            d_half  <= 1'b0; q_half <= 1'b0; q_done <= 1'b0;
            sp_addr <= sp_addr_w; ram_addr <= ram_addr_w;      // from the addresses last written
            np <= sp_addr_w[11:3]; ob_n <= 2'd0; iq <= 2'd0; pf_h <= 1'b0; pf_n <= 2'd0; pf_rd <= 1'b0;
            ds <= d_rd0 ? D_IN : D_OUT; dma_any <= 1'b1;
        end
        D_IN:    if (sp_wr && d_last) ds <= D_END;
        D_OUT: begin
            iq <= o_load ? 2'd0 : iq == 2'd2 ? 2'd2 : iq + 2'd1;
            // (DMEM: a read's pair into the FIFO the cycle after; the head to ob as it empties)
            pf_rd <= dm_rd;
            if (pf_rd) pf[pf_h ^ pf_n[0]] <= m_rdata16[127:64];
            pf_n <= pf_n + 2'(pf_rd) - 2'(o_load && !d_im);
            if (o_load && !d_im) pf_h <= !pf_h;
            if (d_im ? o_load : dm_rd) np <= np + 9'd1;
            if (iq == 2'd1) ih_q <= ia_q;
            if (o_load) begin ob <= d_im ? {ih_q, ia_q} : pf[pf_h]; ob_n <= 2'd2; end
            else if (r_go) ob_n <= ob_n - 2'd1;
            if (r_go && d_last) ds <= D_END;
        end
        D_END:   ds <= D_IDLE;
        default: ds <= D_IDLE;
        endcase
    end
end

endmodule

`ifdef VERILATOR
/* verilator lint_off DECLFILENAME */
`ifndef RSP_DIV_ROM_DEFINED
`define RSP_DIV_ROM_DEFINED
module rsp_div_rom (
    input  wire         clk,
    input  wire  [9:0]  addr,
    output logic [15:0] q
);
    (* rom_style = "block" *) logic [15:0] q_r;
    always_ff @(posedge clk) begin
        case (addr)
            10'd0: q_r <= 16'hffff; 10'd1: q_r <= 16'hff00; 10'd2: q_r <= 16'hfe01; 10'd3: q_r <= 16'hfd04;
            10'd4: q_r <= 16'hfc07; 10'd5: q_r <= 16'hfb0c; 10'd6: q_r <= 16'hfa11; 10'd7: q_r <= 16'hf918;
            10'd8: q_r <= 16'hf81f; 10'd9: q_r <= 16'hf727; 10'd10: q_r <= 16'hf631; 10'd11: q_r <= 16'hf53b;
            10'd12: q_r <= 16'hf446; 10'd13: q_r <= 16'hf352; 10'd14: q_r <= 16'hf25f; 10'd15: q_r <= 16'hf16d;
            10'd16: q_r <= 16'hf07c; 10'd17: q_r <= 16'hef8b; 10'd18: q_r <= 16'hee9c; 10'd19: q_r <= 16'hedae;
            10'd20: q_r <= 16'hecc0; 10'd21: q_r <= 16'hebd3; 10'd22: q_r <= 16'heae8; 10'd23: q_r <= 16'he9fd;
            10'd24: q_r <= 16'he913; 10'd25: q_r <= 16'he829; 10'd26: q_r <= 16'he741; 10'd27: q_r <= 16'he65a;
            10'd28: q_r <= 16'he573; 10'd29: q_r <= 16'he48d; 10'd30: q_r <= 16'he3a9; 10'd31: q_r <= 16'he2c5;
            10'd32: q_r <= 16'he1e1; 10'd33: q_r <= 16'he0ff; 10'd34: q_r <= 16'he01e; 10'd35: q_r <= 16'hdf3d;
            10'd36: q_r <= 16'hde5d; 10'd37: q_r <= 16'hdd7e; 10'd38: q_r <= 16'hdca0; 10'd39: q_r <= 16'hdbc2;
            10'd40: q_r <= 16'hdae6; 10'd41: q_r <= 16'hda0a; 10'd42: q_r <= 16'hd92f; 10'd43: q_r <= 16'hd854;
            10'd44: q_r <= 16'hd77b; 10'd45: q_r <= 16'hd6a2; 10'd46: q_r <= 16'hd5ca; 10'd47: q_r <= 16'hd4f3;
            10'd48: q_r <= 16'hd41d; 10'd49: q_r <= 16'hd347; 10'd50: q_r <= 16'hd272; 10'd51: q_r <= 16'hd19e;
            10'd52: q_r <= 16'hd0cb; 10'd53: q_r <= 16'hcff8; 10'd54: q_r <= 16'hcf26; 10'd55: q_r <= 16'hce55;
            10'd56: q_r <= 16'hcd85; 10'd57: q_r <= 16'hccb5; 10'd58: q_r <= 16'hcbe6; 10'd59: q_r <= 16'hcb18;
            10'd60: q_r <= 16'hca4b; 10'd61: q_r <= 16'hc97e; 10'd62: q_r <= 16'hc8b2; 10'd63: q_r <= 16'hc7e7;
            10'd64: q_r <= 16'hc71c; 10'd65: q_r <= 16'hc652; 10'd66: q_r <= 16'hc589; 10'd67: q_r <= 16'hc4c0;
            10'd68: q_r <= 16'hc3f8; 10'd69: q_r <= 16'hc331; 10'd70: q_r <= 16'hc26b; 10'd71: q_r <= 16'hc1a5;
            10'd72: q_r <= 16'hc0e0; 10'd73: q_r <= 16'hc01c; 10'd74: q_r <= 16'hbf58; 10'd75: q_r <= 16'hbe95;
            10'd76: q_r <= 16'hbdd2; 10'd77: q_r <= 16'hbd10; 10'd78: q_r <= 16'hbc4f; 10'd79: q_r <= 16'hbb8f;
            10'd80: q_r <= 16'hbacf; 10'd81: q_r <= 16'hba10; 10'd82: q_r <= 16'hb951; 10'd83: q_r <= 16'hb894;
            10'd84: q_r <= 16'hb7d6; 10'd85: q_r <= 16'hb71a; 10'd86: q_r <= 16'hb65e; 10'd87: q_r <= 16'hb5a2;
            10'd88: q_r <= 16'hb4e8; 10'd89: q_r <= 16'hb42e; 10'd90: q_r <= 16'hb374; 10'd91: q_r <= 16'hb2bb;
            10'd92: q_r <= 16'hb203; 10'd93: q_r <= 16'hb14b; 10'd94: q_r <= 16'hb094; 10'd95: q_r <= 16'hafde;
            10'd96: q_r <= 16'haf28; 10'd97: q_r <= 16'hae73; 10'd98: q_r <= 16'hadbe; 10'd99: q_r <= 16'had0a;
            10'd100: q_r <= 16'hac57; 10'd101: q_r <= 16'haba4; 10'd102: q_r <= 16'haaf1; 10'd103: q_r <= 16'haa40;
            10'd104: q_r <= 16'ha98e; 10'd105: q_r <= 16'ha8de; 10'd106: q_r <= 16'ha82e; 10'd107: q_r <= 16'ha77e;
            10'd108: q_r <= 16'ha6d0; 10'd109: q_r <= 16'ha621; 10'd110: q_r <= 16'ha574; 10'd111: q_r <= 16'ha4c6;
            10'd112: q_r <= 16'ha41a; 10'd113: q_r <= 16'ha36e; 10'd114: q_r <= 16'ha2c2; 10'd115: q_r <= 16'ha217;
            10'd116: q_r <= 16'ha16d; 10'd117: q_r <= 16'ha0c3; 10'd118: q_r <= 16'ha01a; 10'd119: q_r <= 16'h9f71;
            10'd120: q_r <= 16'h9ec8; 10'd121: q_r <= 16'h9e21; 10'd122: q_r <= 16'h9d79; 10'd123: q_r <= 16'h9cd3;
            10'd124: q_r <= 16'h9c2d; 10'd125: q_r <= 16'h9b87; 10'd126: q_r <= 16'h9ae2; 10'd127: q_r <= 16'h9a3d;
            10'd128: q_r <= 16'h9999; 10'd129: q_r <= 16'h98f6; 10'd130: q_r <= 16'h9852; 10'd131: q_r <= 16'h97b0;
            10'd132: q_r <= 16'h970e; 10'd133: q_r <= 16'h966c; 10'd134: q_r <= 16'h95cb; 10'd135: q_r <= 16'h952b;
            10'd136: q_r <= 16'h948b; 10'd137: q_r <= 16'h93eb; 10'd138: q_r <= 16'h934c; 10'd139: q_r <= 16'h92ad;
            10'd140: q_r <= 16'h920f; 10'd141: q_r <= 16'h9172; 10'd142: q_r <= 16'h90d4; 10'd143: q_r <= 16'h9038;
            10'd144: q_r <= 16'h8f9c; 10'd145: q_r <= 16'h8f00; 10'd146: q_r <= 16'h8e65; 10'd147: q_r <= 16'h8dca;
            10'd148: q_r <= 16'h8d30; 10'd149: q_r <= 16'h8c96; 10'd150: q_r <= 16'h8bfc; 10'd151: q_r <= 16'h8b64;
            10'd152: q_r <= 16'h8acb; 10'd153: q_r <= 16'h8a33; 10'd154: q_r <= 16'h899c; 10'd155: q_r <= 16'h8904;
            10'd156: q_r <= 16'h886e; 10'd157: q_r <= 16'h87d8; 10'd158: q_r <= 16'h8742; 10'd159: q_r <= 16'h86ad;
            10'd160: q_r <= 16'h8618; 10'd161: q_r <= 16'h8583; 10'd162: q_r <= 16'h84f0; 10'd163: q_r <= 16'h845c;
            10'd164: q_r <= 16'h83c9; 10'd165: q_r <= 16'h8336; 10'd166: q_r <= 16'h82a4; 10'd167: q_r <= 16'h8212;
            10'd168: q_r <= 16'h8181; 10'd169: q_r <= 16'h80f0; 10'd170: q_r <= 16'h8060; 10'd171: q_r <= 16'h7fd0;
            10'd172: q_r <= 16'h7f40; 10'd173: q_r <= 16'h7eb1; 10'd174: q_r <= 16'h7e22; 10'd175: q_r <= 16'h7d93;
            10'd176: q_r <= 16'h7d05; 10'd177: q_r <= 16'h7c78; 10'd178: q_r <= 16'h7beb; 10'd179: q_r <= 16'h7b5e;
            10'd180: q_r <= 16'h7ad2; 10'd181: q_r <= 16'h7a46; 10'd182: q_r <= 16'h79ba; 10'd183: q_r <= 16'h792f;
            10'd184: q_r <= 16'h78a4; 10'd185: q_r <= 16'h781a; 10'd186: q_r <= 16'h7790; 10'd187: q_r <= 16'h7706;
            10'd188: q_r <= 16'h767d; 10'd189: q_r <= 16'h75f5; 10'd190: q_r <= 16'h756c; 10'd191: q_r <= 16'h74e4;
            10'd192: q_r <= 16'h745d; 10'd193: q_r <= 16'h73d5; 10'd194: q_r <= 16'h734f; 10'd195: q_r <= 16'h72c8;
            10'd196: q_r <= 16'h7242; 10'd197: q_r <= 16'h71bc; 10'd198: q_r <= 16'h7137; 10'd199: q_r <= 16'h70b2;
            10'd200: q_r <= 16'h702e; 10'd201: q_r <= 16'h6fa9; 10'd202: q_r <= 16'h6f26; 10'd203: q_r <= 16'h6ea2;
            10'd204: q_r <= 16'h6e1f; 10'd205: q_r <= 16'h6d9c; 10'd206: q_r <= 16'h6d1a; 10'd207: q_r <= 16'h6c98;
            10'd208: q_r <= 16'h6c16; 10'd209: q_r <= 16'h6b95; 10'd210: q_r <= 16'h6b14; 10'd211: q_r <= 16'h6a94;
            10'd212: q_r <= 16'h6a13; 10'd213: q_r <= 16'h6993; 10'd214: q_r <= 16'h6914; 10'd215: q_r <= 16'h6895;
            10'd216: q_r <= 16'h6816; 10'd217: q_r <= 16'h6798; 10'd218: q_r <= 16'h6719; 10'd219: q_r <= 16'h669c;
            10'd220: q_r <= 16'h661e; 10'd221: q_r <= 16'h65a1; 10'd222: q_r <= 16'h6524; 10'd223: q_r <= 16'h64a8;
            10'd224: q_r <= 16'h642c; 10'd225: q_r <= 16'h63b0; 10'd226: q_r <= 16'h6335; 10'd227: q_r <= 16'h62ba;
            10'd228: q_r <= 16'h623f; 10'd229: q_r <= 16'h61c5; 10'd230: q_r <= 16'h614b; 10'd231: q_r <= 16'h60d1;
            10'd232: q_r <= 16'h6058; 10'd233: q_r <= 16'h5fdf; 10'd234: q_r <= 16'h5f66; 10'd235: q_r <= 16'h5eed;
            10'd236: q_r <= 16'h5e75; 10'd237: q_r <= 16'h5dfd; 10'd238: q_r <= 16'h5d86; 10'd239: q_r <= 16'h5d0f;
            10'd240: q_r <= 16'h5c98; 10'd241: q_r <= 16'h5c22; 10'd242: q_r <= 16'h5bab; 10'd243: q_r <= 16'h5b35;
            10'd244: q_r <= 16'h5ac0; 10'd245: q_r <= 16'h5a4b; 10'd246: q_r <= 16'h59d6; 10'd247: q_r <= 16'h5961;
            10'd248: q_r <= 16'h58ed; 10'd249: q_r <= 16'h5879; 10'd250: q_r <= 16'h5805; 10'd251: q_r <= 16'h5791;
            10'd252: q_r <= 16'h571e; 10'd253: q_r <= 16'h56ac; 10'd254: q_r <= 16'h5639; 10'd255: q_r <= 16'h55c7;
            10'd256: q_r <= 16'h5555; 10'd257: q_r <= 16'h54e3; 10'd258: q_r <= 16'h5472; 10'd259: q_r <= 16'h5401;
            10'd260: q_r <= 16'h5390; 10'd261: q_r <= 16'h5320; 10'd262: q_r <= 16'h52af; 10'd263: q_r <= 16'h5240;
            10'd264: q_r <= 16'h51d0; 10'd265: q_r <= 16'h5161; 10'd266: q_r <= 16'h50f2; 10'd267: q_r <= 16'h5083;
            10'd268: q_r <= 16'h5015; 10'd269: q_r <= 16'h4fa6; 10'd270: q_r <= 16'h4f38; 10'd271: q_r <= 16'h4ecb;
            10'd272: q_r <= 16'h4e5e; 10'd273: q_r <= 16'h4df1; 10'd274: q_r <= 16'h4d84; 10'd275: q_r <= 16'h4d17;
            10'd276: q_r <= 16'h4cab; 10'd277: q_r <= 16'h4c3f; 10'd278: q_r <= 16'h4bd3; 10'd279: q_r <= 16'h4b68;
            10'd280: q_r <= 16'h4afd; 10'd281: q_r <= 16'h4a92; 10'd282: q_r <= 16'h4a27; 10'd283: q_r <= 16'h49bd;
            10'd284: q_r <= 16'h4953; 10'd285: q_r <= 16'h48e9; 10'd286: q_r <= 16'h4880; 10'd287: q_r <= 16'h4817;
            10'd288: q_r <= 16'h47ae; 10'd289: q_r <= 16'h4745; 10'd290: q_r <= 16'h46dc; 10'd291: q_r <= 16'h4674;
            10'd292: q_r <= 16'h460c; 10'd293: q_r <= 16'h45a5; 10'd294: q_r <= 16'h453d; 10'd295: q_r <= 16'h44d6;
            10'd296: q_r <= 16'h446f; 10'd297: q_r <= 16'h4408; 10'd298: q_r <= 16'h43a2; 10'd299: q_r <= 16'h433c;
            10'd300: q_r <= 16'h42d6; 10'd301: q_r <= 16'h4270; 10'd302: q_r <= 16'h420b; 10'd303: q_r <= 16'h41a6;
            10'd304: q_r <= 16'h4141; 10'd305: q_r <= 16'h40dc; 10'd306: q_r <= 16'h4078; 10'd307: q_r <= 16'h4014;
            10'd308: q_r <= 16'h3fb0; 10'd309: q_r <= 16'h3f4c; 10'd310: q_r <= 16'h3ee8; 10'd311: q_r <= 16'h3e85;
            10'd312: q_r <= 16'h3e22; 10'd313: q_r <= 16'h3dc0; 10'd314: q_r <= 16'h3d5d; 10'd315: q_r <= 16'h3cfb;
            10'd316: q_r <= 16'h3c99; 10'd317: q_r <= 16'h3c37; 10'd318: q_r <= 16'h3bd6; 10'd319: q_r <= 16'h3b74;
            10'd320: q_r <= 16'h3b13; 10'd321: q_r <= 16'h3ab2; 10'd322: q_r <= 16'h3a52; 10'd323: q_r <= 16'h39f1;
            10'd324: q_r <= 16'h3991; 10'd325: q_r <= 16'h3931; 10'd326: q_r <= 16'h38d2; 10'd327: q_r <= 16'h3872;
            10'd328: q_r <= 16'h3813; 10'd329: q_r <= 16'h37b4; 10'd330: q_r <= 16'h3755; 10'd331: q_r <= 16'h36f7;
            10'd332: q_r <= 16'h3698; 10'd333: q_r <= 16'h363a; 10'd334: q_r <= 16'h35dc; 10'd335: q_r <= 16'h357f;
            10'd336: q_r <= 16'h3521; 10'd337: q_r <= 16'h34c4; 10'd338: q_r <= 16'h3467; 10'd339: q_r <= 16'h340a;
            10'd340: q_r <= 16'h33ae; 10'd341: q_r <= 16'h3351; 10'd342: q_r <= 16'h32f5; 10'd343: q_r <= 16'h3299;
            10'd344: q_r <= 16'h323e; 10'd345: q_r <= 16'h31e2; 10'd346: q_r <= 16'h3187; 10'd347: q_r <= 16'h312c;
            10'd348: q_r <= 16'h30d1; 10'd349: q_r <= 16'h3076; 10'd350: q_r <= 16'h301c; 10'd351: q_r <= 16'h2fc2;
            10'd352: q_r <= 16'h2f68; 10'd353: q_r <= 16'h2f0e; 10'd354: q_r <= 16'h2eb4; 10'd355: q_r <= 16'h2e5b;
            10'd356: q_r <= 16'h2e02; 10'd357: q_r <= 16'h2da9; 10'd358: q_r <= 16'h2d50; 10'd359: q_r <= 16'h2cf8;
            10'd360: q_r <= 16'h2c9f; 10'd361: q_r <= 16'h2c47; 10'd362: q_r <= 16'h2bef; 10'd363: q_r <= 16'h2b97;
            10'd364: q_r <= 16'h2b40; 10'd365: q_r <= 16'h2ae8; 10'd366: q_r <= 16'h2a91; 10'd367: q_r <= 16'h2a3a;
            10'd368: q_r <= 16'h29e4; 10'd369: q_r <= 16'h298d; 10'd370: q_r <= 16'h2937; 10'd371: q_r <= 16'h28e0;
            10'd372: q_r <= 16'h288b; 10'd373: q_r <= 16'h2835; 10'd374: q_r <= 16'h27df; 10'd375: q_r <= 16'h278a;
            10'd376: q_r <= 16'h2735; 10'd377: q_r <= 16'h26e0; 10'd378: q_r <= 16'h268b; 10'd379: q_r <= 16'h2636;
            10'd380: q_r <= 16'h25e2; 10'd381: q_r <= 16'h258d; 10'd382: q_r <= 16'h2539; 10'd383: q_r <= 16'h24e5;
            10'd384: q_r <= 16'h2492; 10'd385: q_r <= 16'h243e; 10'd386: q_r <= 16'h23eb; 10'd387: q_r <= 16'h2398;
            10'd388: q_r <= 16'h2345; 10'd389: q_r <= 16'h22f2; 10'd390: q_r <= 16'h22a0; 10'd391: q_r <= 16'h224d;
            10'd392: q_r <= 16'h21fb; 10'd393: q_r <= 16'h21a9; 10'd394: q_r <= 16'h2157; 10'd395: q_r <= 16'h2105;
            10'd396: q_r <= 16'h20b4; 10'd397: q_r <= 16'h2063; 10'd398: q_r <= 16'h2012; 10'd399: q_r <= 16'h1fc1;
            10'd400: q_r <= 16'h1f70; 10'd401: q_r <= 16'h1f1f; 10'd402: q_r <= 16'h1ecf; 10'd403: q_r <= 16'h1e7f;
            10'd404: q_r <= 16'h1e2e; 10'd405: q_r <= 16'h1ddf; 10'd406: q_r <= 16'h1d8f; 10'd407: q_r <= 16'h1d3f;
            10'd408: q_r <= 16'h1cf0; 10'd409: q_r <= 16'h1ca1; 10'd410: q_r <= 16'h1c52; 10'd411: q_r <= 16'h1c03;
            10'd412: q_r <= 16'h1bb4; 10'd413: q_r <= 16'h1b66; 10'd414: q_r <= 16'h1b17; 10'd415: q_r <= 16'h1ac9;
            10'd416: q_r <= 16'h1a7b; 10'd417: q_r <= 16'h1a2d; 10'd418: q_r <= 16'h19e0; 10'd419: q_r <= 16'h1992;
            10'd420: q_r <= 16'h1945; 10'd421: q_r <= 16'h18f8; 10'd422: q_r <= 16'h18ab; 10'd423: q_r <= 16'h185e;
            10'd424: q_r <= 16'h1811; 10'd425: q_r <= 16'h17c4; 10'd426: q_r <= 16'h1778; 10'd427: q_r <= 16'h172c;
            10'd428: q_r <= 16'h16e0; 10'd429: q_r <= 16'h1694; 10'd430: q_r <= 16'h1648; 10'd431: q_r <= 16'h15fd;
            10'd432: q_r <= 16'h15b1; 10'd433: q_r <= 16'h1566; 10'd434: q_r <= 16'h151b; 10'd435: q_r <= 16'h14d0;
            10'd436: q_r <= 16'h1485; 10'd437: q_r <= 16'h143b; 10'd438: q_r <= 16'h13f0; 10'd439: q_r <= 16'h13a6;
            10'd440: q_r <= 16'h135c; 10'd441: q_r <= 16'h1312; 10'd442: q_r <= 16'h12c8; 10'd443: q_r <= 16'h127f;
            10'd444: q_r <= 16'h1235; 10'd445: q_r <= 16'h11ec; 10'd446: q_r <= 16'h11a3; 10'd447: q_r <= 16'h1159;
            10'd448: q_r <= 16'h1111; 10'd449: q_r <= 16'h10c8; 10'd450: q_r <= 16'h107f; 10'd451: q_r <= 16'h1037;
            10'd452: q_r <= 16'h0fef; 10'd453: q_r <= 16'h0fa6; 10'd454: q_r <= 16'h0f5e; 10'd455: q_r <= 16'h0f17;
            10'd456: q_r <= 16'h0ecf; 10'd457: q_r <= 16'h0e87; 10'd458: q_r <= 16'h0e40; 10'd459: q_r <= 16'h0df9;
            10'd460: q_r <= 16'h0db2; 10'd461: q_r <= 16'h0d6b; 10'd462: q_r <= 16'h0d24; 10'd463: q_r <= 16'h0cdd;
            10'd464: q_r <= 16'h0c97; 10'd465: q_r <= 16'h0c50; 10'd466: q_r <= 16'h0c0a; 10'd467: q_r <= 16'h0bc4;
            10'd468: q_r <= 16'h0b7e; 10'd469: q_r <= 16'h0b38; 10'd470: q_r <= 16'h0af2; 10'd471: q_r <= 16'h0aad;
            10'd472: q_r <= 16'h0a68; 10'd473: q_r <= 16'h0a22; 10'd474: q_r <= 16'h09dd; 10'd475: q_r <= 16'h0998;
            10'd476: q_r <= 16'h0953; 10'd477: q_r <= 16'h090f; 10'd478: q_r <= 16'h08ca; 10'd479: q_r <= 16'h0886;
            10'd480: q_r <= 16'h0842; 10'd481: q_r <= 16'h07fd; 10'd482: q_r <= 16'h07b9; 10'd483: q_r <= 16'h0776;
            10'd484: q_r <= 16'h0732; 10'd485: q_r <= 16'h06ee; 10'd486: q_r <= 16'h06ab; 10'd487: q_r <= 16'h0668;
            10'd488: q_r <= 16'h0624; 10'd489: q_r <= 16'h05e1; 10'd490: q_r <= 16'h059e; 10'd491: q_r <= 16'h055c;
            10'd492: q_r <= 16'h0519; 10'd493: q_r <= 16'h04d6; 10'd494: q_r <= 16'h0494; 10'd495: q_r <= 16'h0452;
            10'd496: q_r <= 16'h0410; 10'd497: q_r <= 16'h03ce; 10'd498: q_r <= 16'h038c; 10'd499: q_r <= 16'h034a;
            10'd500: q_r <= 16'h0309; 10'd501: q_r <= 16'h02c7; 10'd502: q_r <= 16'h0286; 10'd503: q_r <= 16'h0245;
            10'd504: q_r <= 16'h0204; 10'd505: q_r <= 16'h01c3; 10'd506: q_r <= 16'h0182; 10'd507: q_r <= 16'h0141;
            10'd508: q_r <= 16'h0101; 10'd509: q_r <= 16'h00c0; 10'd510: q_r <= 16'h0080; 10'd511: q_r <= 16'h0040;
            10'd512: q_r <= 16'h6a09; 10'd513: q_r <= 16'hffff; 10'd514: q_r <= 16'h6955; 10'd515: q_r <= 16'hff00;
            10'd516: q_r <= 16'h68a1; 10'd517: q_r <= 16'hfe02; 10'd518: q_r <= 16'h67ef; 10'd519: q_r <= 16'hfd06;
            10'd520: q_r <= 16'h673e; 10'd521: q_r <= 16'hfc0b; 10'd522: q_r <= 16'h668d; 10'd523: q_r <= 16'hfb12;
            10'd524: q_r <= 16'h65de; 10'd525: q_r <= 16'hfa1a; 10'd526: q_r <= 16'h6530; 10'd527: q_r <= 16'hf923;
            10'd528: q_r <= 16'h6482; 10'd529: q_r <= 16'hf82e; 10'd530: q_r <= 16'h63d6; 10'd531: q_r <= 16'hf73b;
            10'd532: q_r <= 16'h632b; 10'd533: q_r <= 16'hf648; 10'd534: q_r <= 16'h6280; 10'd535: q_r <= 16'hf557;
            10'd536: q_r <= 16'h61d7; 10'd537: q_r <= 16'hf467; 10'd538: q_r <= 16'h612e; 10'd539: q_r <= 16'hf379;
            10'd540: q_r <= 16'h6087; 10'd541: q_r <= 16'hf28c; 10'd542: q_r <= 16'h5fe0; 10'd543: q_r <= 16'hf1a0;
            10'd544: q_r <= 16'h5f3a; 10'd545: q_r <= 16'hf0b6; 10'd546: q_r <= 16'h5e95; 10'd547: q_r <= 16'hefcd;
            10'd548: q_r <= 16'h5df1; 10'd549: q_r <= 16'heee5; 10'd550: q_r <= 16'h5d4e; 10'd551: q_r <= 16'hedff;
            10'd552: q_r <= 16'h5cac; 10'd553: q_r <= 16'hed19; 10'd554: q_r <= 16'h5c0b; 10'd555: q_r <= 16'hec35;
            10'd556: q_r <= 16'h5b6b; 10'd557: q_r <= 16'heb52; 10'd558: q_r <= 16'h5acb; 10'd559: q_r <= 16'hea71;
            10'd560: q_r <= 16'h5a2c; 10'd561: q_r <= 16'he990; 10'd562: q_r <= 16'h598f; 10'd563: q_r <= 16'he8b1;
            10'd564: q_r <= 16'h58f2; 10'd565: q_r <= 16'he7d3; 10'd566: q_r <= 16'h5855; 10'd567: q_r <= 16'he6f6;
            10'd568: q_r <= 16'h57ba; 10'd569: q_r <= 16'he61b; 10'd570: q_r <= 16'h5720; 10'd571: q_r <= 16'he540;
            10'd572: q_r <= 16'h5686; 10'd573: q_r <= 16'he467; 10'd574: q_r <= 16'h55ed; 10'd575: q_r <= 16'he38e;
            10'd576: q_r <= 16'h5555; 10'd577: q_r <= 16'he2b7; 10'd578: q_r <= 16'h54be; 10'd579: q_r <= 16'he1e1;
            10'd580: q_r <= 16'h5427; 10'd581: q_r <= 16'he10d; 10'd582: q_r <= 16'h5391; 10'd583: q_r <= 16'he039;
            10'd584: q_r <= 16'h52fc; 10'd585: q_r <= 16'hdf66; 10'd586: q_r <= 16'h5268; 10'd587: q_r <= 16'hde94;
            10'd588: q_r <= 16'h51d5; 10'd589: q_r <= 16'hddc4; 10'd590: q_r <= 16'h5142; 10'd591: q_r <= 16'hdcf4;
            10'd592: q_r <= 16'h50b0; 10'd593: q_r <= 16'hdc26; 10'd594: q_r <= 16'h501f; 10'd595: q_r <= 16'hdb59;
            10'd596: q_r <= 16'h4f8e; 10'd597: q_r <= 16'hda8c; 10'd598: q_r <= 16'h4efe; 10'd599: q_r <= 16'hd9c1;
            10'd600: q_r <= 16'h4e6f; 10'd601: q_r <= 16'hd8f7; 10'd602: q_r <= 16'h4de1; 10'd603: q_r <= 16'hd82d;
            10'd604: q_r <= 16'h4d53; 10'd605: q_r <= 16'hd765; 10'd606: q_r <= 16'h4cc6; 10'd607: q_r <= 16'hd69e;
            10'd608: q_r <= 16'h4c3a; 10'd609: q_r <= 16'hd5d7; 10'd610: q_r <= 16'h4baf; 10'd611: q_r <= 16'hd512;
            10'd612: q_r <= 16'h4b24; 10'd613: q_r <= 16'hd44e; 10'd614: q_r <= 16'h4a9a; 10'd615: q_r <= 16'hd38a;
            10'd616: q_r <= 16'h4a10; 10'd617: q_r <= 16'hd2c8; 10'd618: q_r <= 16'h4987; 10'd619: q_r <= 16'hd206;
            10'd620: q_r <= 16'h48ff; 10'd621: q_r <= 16'hd146; 10'd622: q_r <= 16'h4878; 10'd623: q_r <= 16'hd086;
            10'd624: q_r <= 16'h47f1; 10'd625: q_r <= 16'hcfc7; 10'd626: q_r <= 16'h476b; 10'd627: q_r <= 16'hcf0a;
            10'd628: q_r <= 16'h46e5; 10'd629: q_r <= 16'hce4d; 10'd630: q_r <= 16'h4660; 10'd631: q_r <= 16'hcd91;
            10'd632: q_r <= 16'h45dc; 10'd633: q_r <= 16'hccd6; 10'd634: q_r <= 16'h4558; 10'd635: q_r <= 16'hcc1b;
            10'd636: q_r <= 16'h44d5; 10'd637: q_r <= 16'hcb62; 10'd638: q_r <= 16'h4453; 10'd639: q_r <= 16'hcaa9;
            10'd640: q_r <= 16'h43d1; 10'd641: q_r <= 16'hc9f2; 10'd642: q_r <= 16'h434f; 10'd643: q_r <= 16'hc93b;
            10'd644: q_r <= 16'h42cf; 10'd645: q_r <= 16'hc885; 10'd646: q_r <= 16'h424f; 10'd647: q_r <= 16'hc7d0;
            10'd648: q_r <= 16'h41cf; 10'd649: q_r <= 16'hc71c; 10'd650: q_r <= 16'h4151; 10'd651: q_r <= 16'hc669;
            10'd652: q_r <= 16'h40d2; 10'd653: q_r <= 16'hc5b6; 10'd654: q_r <= 16'h4055; 10'd655: q_r <= 16'hc504;
            10'd656: q_r <= 16'h3fd8; 10'd657: q_r <= 16'hc453; 10'd658: q_r <= 16'h3f5b; 10'd659: q_r <= 16'hc3a3;
            10'd660: q_r <= 16'h3edf; 10'd661: q_r <= 16'hc2f4; 10'd662: q_r <= 16'h3e64; 10'd663: q_r <= 16'hc245;
            10'd664: q_r <= 16'h3de9; 10'd665: q_r <= 16'hc198; 10'd666: q_r <= 16'h3d6e; 10'd667: q_r <= 16'hc0eb;
            10'd668: q_r <= 16'h3cf5; 10'd669: q_r <= 16'hc03f; 10'd670: q_r <= 16'h3c7c; 10'd671: q_r <= 16'hbf93;
            10'd672: q_r <= 16'h3c03; 10'd673: q_r <= 16'hbee9; 10'd674: q_r <= 16'h3b8b; 10'd675: q_r <= 16'hbe3f;
            10'd676: q_r <= 16'h3b13; 10'd677: q_r <= 16'hbd96; 10'd678: q_r <= 16'h3a9c; 10'd679: q_r <= 16'hbced;
            10'd680: q_r <= 16'h3a26; 10'd681: q_r <= 16'hbc46; 10'd682: q_r <= 16'h39b0; 10'd683: q_r <= 16'hbb9f;
            10'd684: q_r <= 16'h393a; 10'd685: q_r <= 16'hbaf8; 10'd686: q_r <= 16'h38c5; 10'd687: q_r <= 16'hba53;
            10'd688: q_r <= 16'h3851; 10'd689: q_r <= 16'hb9ae; 10'd690: q_r <= 16'h37dd; 10'd691: q_r <= 16'hb90a;
            10'd692: q_r <= 16'h3769; 10'd693: q_r <= 16'hb867; 10'd694: q_r <= 16'h36f6; 10'd695: q_r <= 16'hb7c5;
            10'd696: q_r <= 16'h3684; 10'd697: q_r <= 16'hb723; 10'd698: q_r <= 16'h3612; 10'd699: q_r <= 16'hb681;
            10'd700: q_r <= 16'h35a0; 10'd701: q_r <= 16'hb5e1; 10'd702: q_r <= 16'h352f; 10'd703: q_r <= 16'hb541;
            10'd704: q_r <= 16'h34bf; 10'd705: q_r <= 16'hb4a2; 10'd706: q_r <= 16'h344f; 10'd707: q_r <= 16'hb404;
            10'd708: q_r <= 16'h33df; 10'd709: q_r <= 16'hb366; 10'd710: q_r <= 16'h3370; 10'd711: q_r <= 16'hb2c9;
            10'd712: q_r <= 16'h3302; 10'd713: q_r <= 16'hb22c; 10'd714: q_r <= 16'h3293; 10'd715: q_r <= 16'hb191;
            10'd716: q_r <= 16'h3226; 10'd717: q_r <= 16'hb0f5; 10'd718: q_r <= 16'h31b9; 10'd719: q_r <= 16'hb05b;
            10'd720: q_r <= 16'h314c; 10'd721: q_r <= 16'hafc1; 10'd722: q_r <= 16'h30df; 10'd723: q_r <= 16'haf28;
            10'd724: q_r <= 16'h3074; 10'd725: q_r <= 16'hae8f; 10'd726: q_r <= 16'h3008; 10'd727: q_r <= 16'hadf7;
            10'd728: q_r <= 16'h2f9d; 10'd729: q_r <= 16'had60; 10'd730: q_r <= 16'h2f33; 10'd731: q_r <= 16'hacc9;
            10'd732: q_r <= 16'h2ec8; 10'd733: q_r <= 16'hac33; 10'd734: q_r <= 16'h2e5f; 10'd735: q_r <= 16'hab9e;
            10'd736: q_r <= 16'h2df6; 10'd737: q_r <= 16'hab09; 10'd738: q_r <= 16'h2d8d; 10'd739: q_r <= 16'haa75;
            10'd740: q_r <= 16'h2d24; 10'd741: q_r <= 16'ha9e1; 10'd742: q_r <= 16'h2cbc; 10'd743: q_r <= 16'ha94e;
            10'd744: q_r <= 16'h2c55; 10'd745: q_r <= 16'ha8bc; 10'd746: q_r <= 16'h2bee; 10'd747: q_r <= 16'ha82a;
            10'd748: q_r <= 16'h2b87; 10'd749: q_r <= 16'ha799; 10'd750: q_r <= 16'h2b21; 10'd751: q_r <= 16'ha708;
            10'd752: q_r <= 16'h2abb; 10'd753: q_r <= 16'ha678; 10'd754: q_r <= 16'h2a55; 10'd755: q_r <= 16'ha5e8;
            10'd756: q_r <= 16'h29f0; 10'd757: q_r <= 16'ha559; 10'd758: q_r <= 16'h298b; 10'd759: q_r <= 16'ha4cb;
            10'd760: q_r <= 16'h2927; 10'd761: q_r <= 16'ha43d; 10'd762: q_r <= 16'h28c3; 10'd763: q_r <= 16'ha3b0;
            10'd764: q_r <= 16'h2860; 10'd765: q_r <= 16'ha323; 10'd766: q_r <= 16'h27fd; 10'd767: q_r <= 16'ha297;
            10'd768: q_r <= 16'h279a; 10'd769: q_r <= 16'ha20b; 10'd770: q_r <= 16'h2738; 10'd771: q_r <= 16'ha180;
            10'd772: q_r <= 16'h26d6; 10'd773: q_r <= 16'ha0f6; 10'd774: q_r <= 16'h2674; 10'd775: q_r <= 16'ha06c;
            10'd776: q_r <= 16'h2613; 10'd777: q_r <= 16'h9fe2; 10'd778: q_r <= 16'h25b2; 10'd779: q_r <= 16'h9f59;
            10'd780: q_r <= 16'h2552; 10'd781: q_r <= 16'h9ed1; 10'd782: q_r <= 16'h24f2; 10'd783: q_r <= 16'h9e49;
            10'd784: q_r <= 16'h2492; 10'd785: q_r <= 16'h9dc2; 10'd786: q_r <= 16'h2432; 10'd787: q_r <= 16'h9d3b;
            10'd788: q_r <= 16'h23d3; 10'd789: q_r <= 16'h9cb4; 10'd790: q_r <= 16'h2375; 10'd791: q_r <= 16'h9c2f;
            10'd792: q_r <= 16'h2317; 10'd793: q_r <= 16'h9ba9; 10'd794: q_r <= 16'h22b9; 10'd795: q_r <= 16'h9b25;
            10'd796: q_r <= 16'h225b; 10'd797: q_r <= 16'h9aa0; 10'd798: q_r <= 16'h21fe; 10'd799: q_r <= 16'h9a1c;
            10'd800: q_r <= 16'h21a1; 10'd801: q_r <= 16'h9999; 10'd802: q_r <= 16'h2145; 10'd803: q_r <= 16'h9916;
            10'd804: q_r <= 16'h20e8; 10'd805: q_r <= 16'h9894; 10'd806: q_r <= 16'h208d; 10'd807: q_r <= 16'h9812;
            10'd808: q_r <= 16'h2031; 10'd809: q_r <= 16'h9791; 10'd810: q_r <= 16'h1fd6; 10'd811: q_r <= 16'h9710;
            10'd812: q_r <= 16'h1f7b; 10'd813: q_r <= 16'h968f; 10'd814: q_r <= 16'h1f21; 10'd815: q_r <= 16'h960f;
            10'd816: q_r <= 16'h1ec7; 10'd817: q_r <= 16'h9590; 10'd818: q_r <= 16'h1e6d; 10'd819: q_r <= 16'h9511;
            10'd820: q_r <= 16'h1e13; 10'd821: q_r <= 16'h9492; 10'd822: q_r <= 16'h1dba; 10'd823: q_r <= 16'h9414;
            10'd824: q_r <= 16'h1d61; 10'd825: q_r <= 16'h9397; 10'd826: q_r <= 16'h1d09; 10'd827: q_r <= 16'h931a;
            10'd828: q_r <= 16'h1cb1; 10'd829: q_r <= 16'h929d; 10'd830: q_r <= 16'h1c59; 10'd831: q_r <= 16'h9221;
            10'd832: q_r <= 16'h1c01; 10'd833: q_r <= 16'h91a5; 10'd834: q_r <= 16'h1baa; 10'd835: q_r <= 16'h9129;
            10'd836: q_r <= 16'h1b53; 10'd837: q_r <= 16'h90af; 10'd838: q_r <= 16'h1afc; 10'd839: q_r <= 16'h9034;
            10'd840: q_r <= 16'h1aa6; 10'd841: q_r <= 16'h8fba; 10'd842: q_r <= 16'h1a50; 10'd843: q_r <= 16'h8f40;
            10'd844: q_r <= 16'h19fa; 10'd845: q_r <= 16'h8ec7; 10'd846: q_r <= 16'h19a5; 10'd847: q_r <= 16'h8e4f;
            10'd848: q_r <= 16'h1950; 10'd849: q_r <= 16'h8dd6; 10'd850: q_r <= 16'h18fb; 10'd851: q_r <= 16'h8d5e;
            10'd852: q_r <= 16'h18a7; 10'd853: q_r <= 16'h8ce7; 10'd854: q_r <= 16'h1853; 10'd855: q_r <= 16'h8c70;
            10'd856: q_r <= 16'h17ff; 10'd857: q_r <= 16'h8bf9; 10'd858: q_r <= 16'h17ab; 10'd859: q_r <= 16'h8b83;
            10'd860: q_r <= 16'h1758; 10'd861: q_r <= 16'h8b0d; 10'd862: q_r <= 16'h1705; 10'd863: q_r <= 16'h8a98;
            10'd864: q_r <= 16'h16b2; 10'd865: q_r <= 16'h8a23; 10'd866: q_r <= 16'h1660; 10'd867: q_r <= 16'h89ae;
            10'd868: q_r <= 16'h160d; 10'd869: q_r <= 16'h893a; 10'd870: q_r <= 16'h15bc; 10'd871: q_r <= 16'h88c6;
            10'd872: q_r <= 16'h156a; 10'd873: q_r <= 16'h8853; 10'd874: q_r <= 16'h1519; 10'd875: q_r <= 16'h87e0;
            10'd876: q_r <= 16'h14c8; 10'd877: q_r <= 16'h876d; 10'd878: q_r <= 16'h1477; 10'd879: q_r <= 16'h86fb;
            10'd880: q_r <= 16'h1426; 10'd881: q_r <= 16'h8689; 10'd882: q_r <= 16'h13d6; 10'd883: q_r <= 16'h8618;
            10'd884: q_r <= 16'h1386; 10'd885: q_r <= 16'h85a7; 10'd886: q_r <= 16'h1337; 10'd887: q_r <= 16'h8536;
            10'd888: q_r <= 16'h12e7; 10'd889: q_r <= 16'h84c6; 10'd890: q_r <= 16'h1298; 10'd891: q_r <= 16'h8456;
            10'd892: q_r <= 16'h1249; 10'd893: q_r <= 16'h83e7; 10'd894: q_r <= 16'h11fb; 10'd895: q_r <= 16'h8377;
            10'd896: q_r <= 16'h11ac; 10'd897: q_r <= 16'h8309; 10'd898: q_r <= 16'h115e; 10'd899: q_r <= 16'h829a;
            10'd900: q_r <= 16'h1111; 10'd901: q_r <= 16'h822c; 10'd902: q_r <= 16'h10c3; 10'd903: q_r <= 16'h81bf;
            10'd904: q_r <= 16'h1076; 10'd905: q_r <= 16'h8151; 10'd906: q_r <= 16'h1029; 10'd907: q_r <= 16'h80e4;
            10'd908: q_r <= 16'h0fdc; 10'd909: q_r <= 16'h8078; 10'd910: q_r <= 16'h0f8f; 10'd911: q_r <= 16'h800c;
            10'd912: q_r <= 16'h0f43; 10'd913: q_r <= 16'h7fa0; 10'd914: q_r <= 16'h0ef7; 10'd915: q_r <= 16'h7f34;
            10'd916: q_r <= 16'h0eab; 10'd917: q_r <= 16'h7ec9; 10'd918: q_r <= 16'h0e60; 10'd919: q_r <= 16'h7e5e;
            10'd920: q_r <= 16'h0e15; 10'd921: q_r <= 16'h7df4; 10'd922: q_r <= 16'h0dca; 10'd923: q_r <= 16'h7d8a;
            10'd924: q_r <= 16'h0d7f; 10'd925: q_r <= 16'h7d20; 10'd926: q_r <= 16'h0d34; 10'd927: q_r <= 16'h7cb6;
            10'd928: q_r <= 16'h0cea; 10'd929: q_r <= 16'h7c4d; 10'd930: q_r <= 16'h0ca0; 10'd931: q_r <= 16'h7be5;
            10'd932: q_r <= 16'h0c56; 10'd933: q_r <= 16'h7b7c; 10'd934: q_r <= 16'h0c0c; 10'd935: q_r <= 16'h7b14;
            10'd936: q_r <= 16'h0bc3; 10'd937: q_r <= 16'h7aac; 10'd938: q_r <= 16'h0b7a; 10'd939: q_r <= 16'h7a45;
            10'd940: q_r <= 16'h0b31; 10'd941: q_r <= 16'h79de; 10'd942: q_r <= 16'h0ae8; 10'd943: q_r <= 16'h7977;
            10'd944: q_r <= 16'h0aa0; 10'd945: q_r <= 16'h7911; 10'd946: q_r <= 16'h0a58; 10'd947: q_r <= 16'h78ab;
            10'd948: q_r <= 16'h0a10; 10'd949: q_r <= 16'h7845; 10'd950: q_r <= 16'h09c8; 10'd951: q_r <= 16'h77df;
            10'd952: q_r <= 16'h0981; 10'd953: q_r <= 16'h777a; 10'd954: q_r <= 16'h0939; 10'd955: q_r <= 16'h7715;
            10'd956: q_r <= 16'h08f2; 10'd957: q_r <= 16'h76b1; 10'd958: q_r <= 16'h08ab; 10'd959: q_r <= 16'h764d;
            10'd960: q_r <= 16'h0865; 10'd961: q_r <= 16'h75e9; 10'd962: q_r <= 16'h081e; 10'd963: q_r <= 16'h7585;
            10'd964: q_r <= 16'h07d8; 10'd965: q_r <= 16'h7522; 10'd966: q_r <= 16'h0792; 10'd967: q_r <= 16'h74bf;
            10'd968: q_r <= 16'h074d; 10'd969: q_r <= 16'h745d; 10'd970: q_r <= 16'h0707; 10'd971: q_r <= 16'h73fa;
            10'd972: q_r <= 16'h06c2; 10'd973: q_r <= 16'h7398; 10'd974: q_r <= 16'h067d; 10'd975: q_r <= 16'h7337;
            10'd976: q_r <= 16'h0638; 10'd977: q_r <= 16'h72d5; 10'd978: q_r <= 16'h05f3; 10'd979: q_r <= 16'h7274;
            10'd980: q_r <= 16'h05af; 10'd981: q_r <= 16'h7213; 10'd982: q_r <= 16'h056a; 10'd983: q_r <= 16'h71b3;
            10'd984: q_r <= 16'h0526; 10'd985: q_r <= 16'h7152; 10'd986: q_r <= 16'h04e2; 10'd987: q_r <= 16'h70f2;
            10'd988: q_r <= 16'h049f; 10'd989: q_r <= 16'h7093; 10'd990: q_r <= 16'h045b; 10'd991: q_r <= 16'h7033;
            10'd992: q_r <= 16'h0418; 10'd993: q_r <= 16'h6fd4; 10'd994: q_r <= 16'h03d5; 10'd995: q_r <= 16'h6f76;
            10'd996: q_r <= 16'h0392; 10'd997: q_r <= 16'h6f17; 10'd998: q_r <= 16'h0350; 10'd999: q_r <= 16'h6eb9;
            10'd1000: q_r <= 16'h030d; 10'd1001: q_r <= 16'h6e5b; 10'd1002: q_r <= 16'h02cb; 10'd1003: q_r <= 16'h6dfd;
            10'd1004: q_r <= 16'h0289; 10'd1005: q_r <= 16'h6da0; 10'd1006: q_r <= 16'h0247; 10'd1007: q_r <= 16'h6d43;
            10'd1008: q_r <= 16'h0206; 10'd1009: q_r <= 16'h6ce6; 10'd1010: q_r <= 16'h01c4; 10'd1011: q_r <= 16'h6c8a;
            10'd1012: q_r <= 16'h0183; 10'd1013: q_r <= 16'h6c2d; 10'd1014: q_r <= 16'h0142; 10'd1015: q_r <= 16'h6bd1;
            10'd1016: q_r <= 16'h0101; 10'd1017: q_r <= 16'h6b76; 10'd1018: q_r <= 16'h00c0; 10'd1019: q_r <= 16'h6b1a;
            10'd1020: q_r <= 16'h0080; 10'd1021: q_r <= 16'h6abf; 10'd1022: q_r <= 16'h0040; 10'd1023: q_r <= 16'h6a64;
            default: q_r <= 16'h0000;
        endcase
    end
    assign q = q_r;
endmodule
`endif
/* verilator lint_on DECLFILENAME */
`endif
`default_nettype wire
