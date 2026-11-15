#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "Vgb_host_bridge.h"
#include "verilated.h"

namespace {

constexpr uint32_t kSdrWords  = 16 * 1024 * 1024; // 64 MiB (16M x 32b)
constexpr uint32_t kSramWords = 128 * 1024;       // 512 KiB (128K x 32b)

struct SimEnv {
    Vgb_host_bridge* dut = nullptr;
    std::vector<uint32_t> sdram;
    std::vector<uint32_t> sram;

    // Multi-cycle SDRAM read pipeline (models sdr_arb + sdr_ctrl latency)
    int      sdr_rd_countdown = 0;
    uint32_t sdr_rd_pending_data = 0;
    int      sram_wait = 0;

    // Captured outputs from 1-cycle pulses / scanner
    uint32_t pad_ram[16] = {};
    uint32_t ia_regs[32] = {};
    uint32_t ia_wr_count = 0;
    uint32_t last_ia_addr = 0;
    uint32_t last_ia_data = 0;
    uint32_t rom_cache_inv_count = 0;
    uint32_t complete_trig_count = 0;

    // Audio sample tracking
    int16_t  prev_aud_l = 0;
    int16_t  prev_aud_r = 0;
    uint32_t aud_transitions = 0;
    std::vector<uint32_t> popped_audio;

    uint64_t cycle = 0;

    SimEnv() : sdram(kSdrWords, 0), sram(kSramWords, 0) {
        dut = new Vgb_host_bridge;
        init_inputs();
    }

    ~SimEnv() { delete dut; }

    void init_inputs() {
        dut->clk = 0;
        dut->rst = 1;
        dut->sdr_ready = 0;
        dut->sram_ready = 0;

        dut->host_mem_enable = 0;
        dut->host_mem_write = 0;
        dut->host_mem_address = 0;
        dut->host_mem_dataWrite = 0;
        dut->host_commandHost_request = 0;
        dut->host_commandCore_busy = 0;
        dut->host_commandCore_done = 0;
        dut->host_commandCore_error = 0;

        dut->input_slots_0_active = 0;
        dut->input_slots_0_deviceType = 0;
        dut->input_slots_0_buttons_a = 0;
        dut->input_slots_0_buttons_b = 0;
        dut->input_slots_0_buttons_x = 0;
        dut->input_slots_0_buttons_y = 0;
        dut->input_slots_0_buttons_up = 0;
        dut->input_slots_0_buttons_down = 0;
        dut->input_slots_0_buttons_left = 0;
        dut->input_slots_0_buttons_right = 0;
        dut->input_slots_0_buttons_l1 = 0;
        dut->input_slots_0_buttons_r1 = 0;
        dut->input_slots_0_buttons_l2 = 0;
        dut->input_slots_0_buttons_r2 = 0;
        dut->input_slots_0_buttons_l3 = 0;
        dut->input_slots_0_buttons_r3 = 0;
        dut->input_slots_0_buttons_start = 0;
        dut->input_slots_0_buttons_select = 0;
        dut->input_slots_0_analog_leftX = 0;
        dut->input_slots_0_analog_leftY = 0;
        dut->input_slots_0_analog_rightX = 0;
        dut->input_slots_0_analog_rightY = 0;
        dut->input_slots_0_analog_leftTrigger = 0;
        dut->input_slots_0_analog_rightTrigger = 0;

        dut->input_slots_1_active = 0;
        dut->input_slots_1_deviceType = 0;
        dut->input_slots_1_buttons_a = 0;
        dut->input_slots_1_buttons_b = 0;
        dut->input_slots_1_buttons_x = 0;
        dut->input_slots_1_buttons_y = 0;
        dut->input_slots_1_buttons_up = 0;
        dut->input_slots_1_buttons_down = 0;
        dut->input_slots_1_buttons_left = 0;
        dut->input_slots_1_buttons_right = 0;
        dut->input_slots_1_buttons_l1 = 0;
        dut->input_slots_1_buttons_r1 = 0;
        dut->input_slots_1_buttons_l2 = 0;
        dut->input_slots_1_buttons_r2 = 0;
        dut->input_slots_1_buttons_l3 = 0;
        dut->input_slots_1_buttons_r3 = 0;
        dut->input_slots_1_buttons_start = 0;
        dut->input_slots_1_buttons_select = 0;
        dut->input_slots_1_analog_leftX = 0;
        dut->input_slots_1_analog_leftY = 0;
        dut->input_slots_1_analog_rightX = 0;
        dut->input_slots_1_analog_rightY = 0;
        dut->input_slots_1_analog_leftTrigger = 0;
        dut->input_slots_1_analog_rightTrigger = 0;

        dut->input_slots_2_active = 0;
        dut->input_slots_2_deviceType = 0;
        dut->input_slots_2_buttons_a = 0;
        dut->input_slots_2_buttons_b = 0;
        dut->input_slots_2_buttons_x = 0;
        dut->input_slots_2_buttons_y = 0;
        dut->input_slots_2_buttons_up = 0;
        dut->input_slots_2_buttons_down = 0;
        dut->input_slots_2_buttons_left = 0;
        dut->input_slots_2_buttons_right = 0;
        dut->input_slots_2_buttons_l1 = 0;
        dut->input_slots_2_buttons_r1 = 0;
        dut->input_slots_2_buttons_l2 = 0;
        dut->input_slots_2_buttons_r2 = 0;
        dut->input_slots_2_buttons_l3 = 0;
        dut->input_slots_2_buttons_r3 = 0;
        dut->input_slots_2_buttons_start = 0;
        dut->input_slots_2_buttons_select = 0;
        dut->input_slots_2_analog_leftX = 0;
        dut->input_slots_2_analog_leftY = 0;
        dut->input_slots_2_analog_rightX = 0;
        dut->input_slots_2_analog_rightY = 0;
        dut->input_slots_2_analog_leftTrigger = 0;
        dut->input_slots_2_analog_rightTrigger = 0;

        dut->input_slots_3_active = 0;
        dut->input_slots_3_deviceType = 0;
        dut->input_slots_3_buttons_a = 0;
        dut->input_slots_3_buttons_b = 0;
        dut->input_slots_3_buttons_x = 0;
        dut->input_slots_3_buttons_y = 0;
        dut->input_slots_3_buttons_up = 0;
        dut->input_slots_3_buttons_down = 0;
        dut->input_slots_3_buttons_left = 0;
        dut->input_slots_3_buttons_right = 0;
        dut->input_slots_3_buttons_l1 = 0;
        dut->input_slots_3_buttons_r1 = 0;
        dut->input_slots_3_buttons_l2 = 0;
        dut->input_slots_3_buttons_r2 = 0;
        dut->input_slots_3_buttons_l3 = 0;
        dut->input_slots_3_buttons_r3 = 0;
        dut->input_slots_3_buttons_start = 0;
        dut->input_slots_3_buttons_select = 0;
        dut->input_slots_3_analog_leftX = 0;
        dut->input_slots_3_analog_leftY = 0;
        dut->input_slots_3_analog_rightX = 0;
        dut->input_slots_3_analog_rightY = 0;
        dut->input_slots_3_analog_leftTrigger = 0;
        dut->input_slots_3_analog_rightTrigger = 0;

        dut->rumble_motor_on = 0;
        dut->apf_audio_bus_out = 0;
        dut->apf_audio_bus_wr = 0;
        dut->apf_audio_flush = 0;
        dut->apf_audio_playback_en = 0;

        dut->apf_bridge_data_offset = 0;
        dut->apf_bridge_file_size_wr = 0;
        dut->apf_bridge_length = 0;
        dut->apf_bridge_new_file_size_data = 0;
        dut->apf_bridge_ram_data_address = 0;
        dut->apf_bridge_request_getfile = 0;
        dut->apf_bridge_request_openfile = 0;
        dut->apf_bridge_request_read = 0;
        dut->apf_bridge_request_write = 0;
        dut->apf_bridge_request_setsize = 0;
        dut->apf_bridge_request_flush = 0;
        dut->apf_bridge_slot_id = 0;

        dut->br_sdr_ready = 0;
        dut->br_sdr_rvalid = 0;
        dut->br_sdr_rdata = 0;
        dut->h_sram_ack = 0;
        dut->h_sram_rdata = 0;
    }

    void tick() {
        // Drive SDRAM & SRAM slave models before rising edge
        dut->br_sdr_ready = (sdr_rd_countdown == 0) ? 1 : 0;
        dut->br_sdr_rvalid = (sdr_rd_countdown == 1) ? 1 : 0;
        dut->br_sdr_rdata = (sdr_rd_countdown == 1) ? sdr_rd_pending_data : 0;

        if (dut->h_sram_valid) {
            if (sram_wait < 1) {
                dut->h_sram_ack = 0;
                dut->h_sram_rdata = 0;
            } else {
                dut->h_sram_ack = 1;
                dut->h_sram_rdata = sram[dut->h_sram_addr & (kSramWords - 1)];
            }
        } else {
            dut->h_sram_ack = 0;
            dut->h_sram_rdata = 0;
        }

        dut->eval();

        // Capture SDRAM / SRAM requests sampled on posedge clk
        const bool sdr_accept  = dut->br_sdr_valid && dut->br_sdr_ready && !dut->rst;
        const bool sdr_we      = dut->br_sdr_we;
        const uint32_t sdr_a   = dut->br_sdr_addr & (kSdrWords - 1);
        const uint32_t sdr_wd  = dut->br_sdr_wdata;

        const bool sram_active = dut->h_sram_valid && !dut->rst;
        const bool sram_accept = dut->h_sram_valid && dut->h_sram_ack && !dut->rst;
        const bool sram_we     = dut->h_sram_we;
        const uint32_t sram_a  = dut->h_sram_addr & (kSramWords - 1);
        const uint32_t sram_wd = dut->h_sram_wdata;

        // Rising edge
        dut->clk = 1;
        dut->eval();

        // Update memory models after rising edge
        if (sdr_rd_countdown > 0) sdr_rd_countdown--;
        if (sdr_accept) {
            if (sdr_we) {
                sdram[sdr_a] = sdr_wd;
            } else {
                sdr_rd_pending_data = sdram[sdr_a];
                sdr_rd_countdown = 3; // 3-cycle read pipeline latency
            }
        }

        if (sram_accept) {
            if (sram_we) sram[sram_a] = sram_wd;
            sram_wait = 0;
        } else if (sram_active) {
            sram_wait++;
        } else {
            sram_wait = 0;
        }

        // Capture registered bridge outputs
        if (!dut->rst) {
            if (dut->apf_pad_we) {
                pad_ram[dut->apf_pad_wa & 0xF] = dut->apf_pad_wd;
            }
            if (dut->apf_interact_wr) {
                ia_wr_count++;
                last_ia_addr = dut->apf_interact_address;
                last_ia_data = dut->apf_interact_data;
                ia_regs[dut->apf_interact_address & 0x1F] = dut->apf_interact_data;
            }
            if (dut->rom_cache_inv) rom_cache_inv_count++;
            if (dut->apf_bridge_complete_trigger) complete_trig_count++;

            int16_t cur_l = static_cast<int16_t>(dut->audio_left);
            int16_t cur_r = static_cast<int16_t>(dut->audio_right);
            if (cur_l != prev_aud_l || cur_r != prev_aud_r) {
                aud_transitions++;
                popped_audio.push_back((static_cast<uint32_t>( static_cast<uint16_t>(cur_l) ) << 16) |
                                        static_cast<uint16_t>(cur_r));
                prev_aud_l = cur_l;
                prev_aud_r = cur_r;
            }
        }

        // Falling edge
        dut->clk = 0;
        dut->eval();
        cycle++;
    }

    void reset_dut(int cycles = 8) {
        dut->rst = 1;
        for (int i = 0; i < cycles; i++) tick();
        dut->rst = 0;
        tick();
    }

    void host_write32(uint32_t addr, uint32_t data) {
        dut->host_mem_enable = 1;
        dut->host_mem_write = 1;
        dut->host_mem_address = addr;
        dut->host_mem_dataWrite = data;
        int guard = 0;
        while (true) {
            tick();
            if (dut->host_mem_done) break;
            assert(++guard < 200 && "host_write32 timeout");
        }
        dut->host_mem_enable = 0;
        dut->host_mem_write = 0;
        // Note: test back-to-back without extra idle cycle works too; we also test back-to-back explicitly!
    }

    uint32_t host_read32(uint32_t addr) {
        dut->host_mem_enable = 1;
        dut->host_mem_write = 0;
        dut->host_mem_address = addr;
        int guard = 0;
        while (true) {
            tick();
            if (dut->host_mem_done) break;
            assert(++guard < 200 && "host_read32 timeout");
        }
        uint32_t val = dut->host_mem_dataRead;
        dut->host_mem_enable = 0;
        return val;
    }

    uint32_t host_cmd(uint16_t opcode, uint32_t p1 = 0, uint32_t p2 = 0, uint32_t p3 = 0) {
        host_write32(0xF0000000u, opcode);
        host_write32(0xF0000004u, p1);
        host_write32(0xF0000008u, p2);
        host_write32(0xF000000Cu, p3);

        dut->host_commandHost_request = 1;
        int guard = 0;
        bool saw_busy = false;
        while (true) {
            tick();
            if (dut->host_commandHost_busy) saw_busy = true;
            if (dut->host_commandHost_done) break;
            assert(++guard < 100 && "host_cmd timeout");
        }
        assert(saw_busy && "commandHost must raise busy before done");
        assert(!dut->host_commandHost_error && "unexpected commandHost error");
        uint32_t res0 = host_read32(0xF0000000u);
        dut->host_commandHost_request = 0;
        tick();
        assert(!dut->host_commandHost_done && !dut->host_commandHost_busy);
        return res0;
    }

    // Helper: pack 4 file bytes [b0, b1, b2, b3] into Game Bub's LE HostV0 32-bit word
    static uint32_t pack_le(uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3) {
        return static_cast<uint32_t>(b0) |
               (static_cast<uint32_t>(b1) << 8) |
               (static_cast<uint32_t>(b2) << 16) |
               (static_cast<uint32_t>(b3) << 24);
    }
};

void check_eq(const char* label, uint32_t got, uint32_t want) {
    if (got != want) {
        std::fprintf(stderr, "FAIL [%s]: got 0x%08x (%u), want 0x%08x (%u)\n",
                     label, got, got, want, want);
        std::exit(1);
    }
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    SimEnv env;
    env.reset_dut();

    // =========================================================================
    // Test 1: GetStatus lifecycle (Initialize -> Setup -> Halt -> Run -> Halt -> Run)
    // =========================================================================
    std::printf("[1/7] Testing GetStatus & lifecycle commands...\n");
    check_eq("StatusInitialize (0,0)", env.host_cmd(0x0000), 1u);
    env.dut->sdr_ready = 1;
    check_eq("StatusInitialize (1,0)", env.host_cmd(0x0000), 1u);
    env.dut->sdr_ready = 0;
    env.dut->sram_ready = 1;
    check_eq("StatusInitialize (0,1)", env.host_cmd(0x0000), 1u);
    env.dut->sdr_ready = 1;
    env.dut->sram_ready = 1;
    check_eq("StatusSetup (1,1)", env.host_cmd(0x0000), 2u);
    check_eq("host_loaded before setup", env.dut->apf_bridge_host_loaded, 0u);
    check_eq("host_reset_n before setup", env.dut->apf_bridge_host_reset_n, 0u);

    // =========================================================================
    // Test 2: ROM Endianness (.z64, .v64, .n64, raw MIPS binary) & n64rt.sys
    // =========================================================================
    std::printf("[2/7] Testing .z64 / .v64 / .n64 ROM swap & SDRAM round-trip...\n");

    // 2a. n64rt.sys (File ID 3 at 0x0000_0000) — back-to-back writes!
    env.host_cmd(0x0300, 3); // FileWriteStart(3)
    env.dut->host_mem_enable = 1;
    env.dut->host_mem_write = 1;
    const uint32_t rt_le[2] = {
        SimEnv::pack_le(0x10, 0x00, 0x00, 0x03), // MIPS `b 1f`
        SimEnv::pack_le(0x00, 0x00, 0x00, 0x00)  // `nop`
    };
    for (int i = 0; i < 2; i++) {
        env.dut->host_mem_address = i * 4u;
        env.dut->host_mem_dataWrite = rt_le[i];
        do { env.tick(); } while (!env.dut->host_mem_done);
    }
    env.dut->host_mem_enable = 0;
    env.dut->host_mem_write = 0;
    env.host_cmd(0x0301, 3, 8, 0); // FileWriteEnd(3, 8)
    check_eq("n64rt word 0 in BE SDRAM", env.sdram[0], 0x10000003u);
    check_eq("n64rt readback LE", env.host_read32(0x00000000u), rt_le[0]);

    // 2b. .z64 ROM [80, 37, 12, 40], ['S', 'M', '6', '4']
    uint32_t inv_before = env.rom_cache_inv_count;
    env.host_cmd(0x0300, 0);
    env.host_write32(0x00100000u, SimEnv::pack_le(0x80, 0x37, 0x12, 0x40));
    env.host_write32(0x00100004u, SimEnv::pack_le('S', 'M', '6', '4'));
    env.host_cmd(0x0301, 0, 8, 0);
    check_eq(".z64 magic in SDRAM", env.sdram[0x040000], 0x80371240u);
    check_eq(".z64 word1 in SDRAM", env.sdram[0x040001], 0x534D3634u);
    assert(env.rom_cache_inv_count >= inv_before + 2);

    // 2c. .v64 ROM [37, 80, 40, 12], ['M', 'S', '4', '6']
    env.sdram[0x040000] = 0;
    env.sdram[0x040001] = 0;
    env.host_cmd(0x0300, 0);
    env.host_write32(0x00100000u, SimEnv::pack_le(0x37, 0x80, 0x40, 0x12));
    env.host_write32(0x00100004u, SimEnv::pack_le('M', 'S', '4', '6'));
    env.host_cmd(0x0301, 0, 8, 0);
    check_eq(".v64 magic in SDRAM", env.sdram[0x040000], 0x80371240u);
    check_eq(".v64 word1 in SDRAM", env.sdram[0x040001], 0x534D3634u);

    // 2d. .n64 ROM [40, 12, 37, 80], ['4', '6', 'M', 'S']
    env.sdram[0x040000] = 0;
    env.sdram[0x040001] = 0;
    env.host_cmd(0x0300, 0);
    env.host_write32(0x00100000u, SimEnv::pack_le(0x40, 0x12, 0x37, 0x80));
    env.host_write32(0x00100004u, SimEnv::pack_le('4', '6', 'M', 'S'));
    env.host_cmd(0x0301, 0, 0x00800000u, 0);
    check_eq(".n64 magic in SDRAM", env.sdram[0x040000], 0x80371240u);
    check_eq(".n64 word1 in SDRAM", env.sdram[0x040001], 0x534D3634u);
    env.dut->apf_bridge_slot_id = 0;
    env.tick();
    check_eq("slot 0 file size", env.dut->apf_bridge_file_size, 0x00800000u);

    // 2e. Raw MIPS test binary (cpu_test.bin) -> byte-swapped into BE order
    env.host_cmd(0x0300, 0);
    env.host_write32(0x00100000u, SimEnv::pack_le(0x10, 0x00, 0x00, 0x5F));
    env.host_cmd(0x0301, 0, 4096, 0);
    check_eq("raw MIPS bin in SDRAM", env.sdram[0x040000], 0x1000005Fu);

    // =========================================================================
    // Test 3: .sav (ID 1) & .mpk (ID 2) 0xFF-init detection & byte-exact save
    // =========================================================================
    std::printf("[3/7] Testing .sav / .mpk 0xFF-init suppression & byte-exact save...\n");
    env.host_cmd(0x0300, 1); // FileWriteStart(1)
    for (uint32_t off = 0; off < 64; off += 4) {
        env.host_write32(0x34140000u + off, 0xFFFFFFFFu);
    }
    env.host_cmd(0x0301, 1, 0x00020000u, 0); // FileWriteEnd(1, 128 KiB of 0xFF)

    env.dut->apf_bridge_slot_id = 1;
    env.tick();
    check_eq("untouched 0xFF .sav size seen by n64rt", env.dut->apf_bridge_file_size, 0u);
    check_eq("untouched 0xFF .sav FileReadStart", env.host_cmd(0x0302, 1), 0u);
    env.host_cmd(0x0303, 1);

    // Now simulate n64rt formatting/writing a 512-byte EEPROM save
    env.dut->apf_bridge_slot_id = 1;
    env.dut->apf_bridge_new_file_size_data = 512u;
    env.dut->apf_bridge_file_size_wr = 1;
    env.tick();
    env.dut->apf_bridge_file_size_wr = 0;
    env.tick();
    check_eq("updated .sav size seen by n64rt", env.dut->apf_bridge_file_size, 512u);

    // n64rt writes big-endian bytes [0..511] into SRAM at 0x3414_0000 (SRAM word 0x10000)
    for (uint32_t w = 0; w < 512 / 4; w++) {
        uint8_t b0 = static_cast<uint8_t>(4 * w + 0) ^ 0xA5u;
        uint8_t b1 = static_cast<uint8_t>(4 * w + 1) ^ 0x5Au;
        uint8_t b2 = static_cast<uint8_t>(4 * w + 2) ^ 0x3Cu;
        uint8_t b3 = static_cast<uint8_t>(4 * w + 3) ^ 0xC3u;
        env.sram[0x10000 + w] = (static_cast<uint32_t>(b0) << 24) |
                                (static_cast<uint32_t>(b1) << 16) |
                                (static_cast<uint32_t>(b2) << 8)  |
                                static_cast<uint32_t>(b3);
    }

    check_eq("512B .sav FileReadStart", env.host_cmd(0x0302, 1), 512u);
    for (uint32_t w = 0; w < 512 / 4; w++) {
        uint32_t le_word = env.host_read32(0x34140000u + 4 * w);
        uint8_t got0 = le_word & 0xFFu;
        uint8_t got1 = (le_word >> 8) & 0xFFu;
        uint8_t got2 = (le_word >> 16) & 0xFFu;
        uint8_t got3 = (le_word >> 24) & 0xFFu;
        check_eq("sav byte 0", got0, static_cast<uint8_t>(4 * w + 0) ^ 0xA5u);
        check_eq("sav byte 1", got1, static_cast<uint8_t>(4 * w + 1) ^ 0x5Au);
        check_eq("sav byte 2", got2, static_cast<uint8_t>(4 * w + 2) ^ 0x3Cu);
        check_eq("sav byte 3", got3, static_cast<uint8_t>(4 * w + 3) ^ 0xC3u);
    }
    env.host_cmd(0x0303, 1);

    // Complete setup and start core!
    env.host_cmd(0x0102); // SetupComplete
    check_eq("StatusCoreHalt", env.host_cmd(0x0000), 3u);
    check_eq("host_loaded after SetupComplete", env.dut->apf_bridge_host_loaded, 1u);
    check_eq("host_reset_n in Halt", env.dut->apf_bridge_host_reset_n, 0u);

    env.host_cmd(0x0100); // CoreRun
    check_eq("StatusCoreRun", env.host_cmd(0x0000), 4u);
    check_eq("host_reset_n in Run", env.dut->apf_bridge_host_reset_n, 1u);

    // =========================================================================
    // Test 4: settings.json + mask RMW + apf_interact + VibrateV0
    // =========================================================================
    std::printf("[4/7] Testing settings.json register bank, apf_interact, and VibrateV0...\n");
    env.host_write32(0x70000000u, 2u); // Controller 1 Pak = Rumble Pak
    check_eq("ia_regs[2] (Pak)", env.ia_regs[2], 2u);
    check_eq("cfg_reg[0] readback", env.host_read32(0x70000000u), 2u);

    // Test VI Deblur (cfg 6) + 32-bit Color (cfg 7) -> field 17 (INTERACT2[6:5])
    env.host_write32(0x70000018u, 1u); // Deblur = 1
    check_eq("ia_regs[17] (Deblur=1, Out32=0)", env.ia_regs[17], 0x2u);
    env.host_write32(0x7000001Cu, 1u); // Out32 = 1
    check_eq("ia_regs[17] (Deblur=1, Out32=1)", env.ia_regs[17], 0x3u);

    // Test mask RMW on Scaling Filter (cfg 8: 0x70000020)
    env.host_write32(0x70000020u, 0x0u);
    check_eq("vid_horiz_blend_en (0)", env.dut->vid_horiz_blend_en, 1u);
    check_eq("vid_dither_en (0)", env.dut->vid_dither_en, 1u);
    uint32_t old_filt = env.host_read32(0x70000020u);
    env.host_write32(0x70000020u, (old_filt & 0xFFFFFFFCu) | 0x3u); // Crisp Raw 6b
    check_eq("cfg_reg[8] readback", env.host_read32(0x70000020u), 0x3u);
    check_eq("vid_horiz_blend_en (3)", env.dut->vid_horiz_blend_en, 0u);
    check_eq("vid_dither_en (3)", env.dut->vid_dither_en, 0u);

    // Test SDRAM phase target (cfg 11: 0x7000002C)
    env.host_write32(0x7000002Cu, static_cast<uint32_t>(-12));
    check_eq("sdram_ps_target", static_cast<uint8_t>(env.dut->sdram_ps_target), static_cast<uint8_t>(-12));

    // Test Restart Game action (cfg 10: 0x70000028) -> 1-cycle pulse ONLY!
    uint32_t ia_cnt0 = env.ia_wr_count;
    env.host_write32(0x70000028u, 1u);
    check_eq("Restart Game ia_addr", env.last_ia_addr, 12u);
    check_eq("Restart Game ia_data", env.last_ia_data, 1u);
    check_eq("Restart Game single pulse", env.ia_wr_count, ia_cnt0 + 1);
    for (int i = 0; i < 20; i++) env.tick();
    check_eq("No continuous overwrite of INTERACT1", env.ia_wr_count, ia_cnt0 + 1);

    // Test VibrateV0 gating with NotifyFocus & CoreRun
    env.dut->rumble_motor_on = 1;
    env.tick();
    check_eq("Vibrate off when unfocused", env.dut->vibrate_mode, 0u);
    env.host_cmd(0x0200, 1); // NotifyFocus(1)
    check_eq("Vibrate on when running + focused + motor", env.dut->vibrate_mode, 1u);
    env.host_cmd(0x0101); // CoreHalt
    check_eq("Vibrate off when halted", env.dut->vibrate_mode, 0u);
    env.host_cmd(0x0100); // CoreRun
    check_eq("Vibrate back on when running", env.dut->vibrate_mode, 1u);
    env.dut->rumble_motor_on = 0;
    env.tick();
    check_eq("Vibrate off when motor cleared", env.dut->vibrate_mode, 0u);

    // =========================================================================
    // Test 5: InputExtendedV0(4) -> pad_wa / pad_wd Scanner
    // =========================================================================
    std::printf("[5/7] Testing InputExtendedV0(4) scanner & stick/trigger mapping...\n");
    // Slot 0: Analog gamepad (type=3), A + Start, leftY = -127 (up), leftX = +127 (right),
    //         rightY = -128 (clamped to -127 -> 0x01), leftTrigger = 64 (-> L2!), rightTrigger = 63 (no R2)
    env.dut->input_slots_0_active = 1;
    env.dut->input_slots_0_deviceType = 3;
    env.dut->input_slots_0_buttons_a = 1;
    env.dut->input_slots_0_buttons_start = 1;
    env.dut->input_slots_0_analog_leftX = 127;
    env.dut->input_slots_0_analog_leftY = static_cast<uint8_t>(-127);
    env.dut->input_slots_0_analog_rightX = 0;
    env.dut->input_slots_0_analog_rightY = static_cast<uint8_t>(-128);
    env.dut->input_slots_0_analog_leftTrigger = 64;
    env.dut->input_slots_0_analog_rightTrigger = 63;

    // Slot 1: Handheld (type=1), Up + R1
    env.dut->input_slots_1_active = 1;
    env.dut->input_slots_1_deviceType = 1;
    env.dut->input_slots_1_buttons_up = 1;
    env.dut->input_slots_1_buttons_r1 = 1;

    // Run 24 cycles (2 full scan sweeps of wa=0..11)
    for (int i = 0; i < 24; i++) env.tick();

    // Slot 0 KEY: type=3<<28 | start(1<<15) | L2(1<<10) | A(1<<4)
    check_eq("Slot 0 KEY", env.pad_ram[0], (3u << 28) | (1u << 15) | (1u << 10) | (1u << 4));
    // Slot 0 JOY: {RY=-128->0x01, RX=0->0x80, LY=-127->0x01, LX=+127->0xFF}
    check_eq("Slot 0 JOY", env.pad_ram[4], 0x018001FFu);
    // Slot 0 TRIG: {16'd0, R=63, L=64}
    check_eq("Slot 0 TRIG", env.pad_ram[8], (63u << 8) | 64u);

    // Slot 1 KEY: type=1<<28 | R1(1<<9) | Up(1<<0)
    check_eq("Slot 1 KEY", env.pad_ram[1], (1u << 28) | (1u << 9) | 1u);
    check_eq("Slot 1 JOY (centered)", env.pad_ram[5], 0x80808080u);

    // Slot 2 (inactive): KEY=0, JOY=0x80808080, TRIG=0
    check_eq("Slot 2 KEY (inactive)", env.pad_ram[2], 0u);
    check_eq("Slot 2 JOY (inactive)", env.pad_ram[6], 0x80808080u);
    check_eq("Slot 2 TRIG (inactive)", env.pad_ram[10], 0u);

    // =========================================================================
    // Test 6: AudioV0 512-Word FIFO & Exact 48,000 Hz Pacer over 625,000 cycles
    // =========================================================================
    std::printf("[6/7] Testing AudioV0 512-word FIFO & exact 48,000 Hz pacer (625,000 cycles = 10 ms)...\n");
    env.dut->apf_audio_flush = 1;
    env.tick();
    env.dut->apf_audio_flush = 0;
    env.dut->apf_audio_playback_en = 1;

    // Reset pacer phase alignment by doing a fresh reset + SetupComplete + CoreRun right before 625,000-cycle window
    env.reset_dut();
    env.dut->sdr_ready = 1;
    env.dut->sram_ready = 1;
    env.host_cmd(0x0102); // SetupComplete
    env.host_cmd(0x0100); // CoreRun
    env.dut->apf_audio_playback_en = 1;

    // Synchronize to right after a 48 kHz tick or measure exact ticks over 625,000 cycles!
    // Wait: 625,000 * 12 = 7,500,000 = 480 * 15,625 EXACTLY!
    // Regardless of the starting value of aud_acc in [0, 15624], ANY contiguous window of 625,000 cycles
    // advances the rational accumulator by 480 * 15,625, so it fires aud_tick_48k EXACTLY 480 times!
    env.aud_transitions = 0;
    env.popped_audio.clear();
    uint32_t next_sample_idx = 1;

    // Pre-fill 256 unique stereo samples into the FIFO before starting the 625,000-cycle window
    // Wait: those pre-fill cycles also advance aud_acc, which as proven above STILL yields EXACTLY 480 ticks in 625,000 cycles!
    for (int i = 0; i < 256; i++) {
        int16_t l = static_cast<int16_t>(next_sample_idx);
        int16_t r = static_cast<int16_t>(-static_cast<int>(next_sample_idx));
        env.dut->apf_audio_bus_wr = 1;
        env.dut->apf_audio_bus_out = (static_cast<uint32_t>(static_cast<uint16_t>(l)) << 16) |
                                      static_cast<uint16_t>(r);
        env.tick();
        next_sample_idx++;
    }
    env.dut->apf_audio_bus_wr = 0;

    // Reset measurement counters at start of exact 625,000-cycle window
    const size_t base_popped = env.popped_audio.size();
    for (uint32_t c = 0; c < 625000u; c++) {
        // Keep FIFO topped up around 256 words just like rcp_ai.sv
        if (env.dut->apf_audio_buffer_fill < 256u) {
            int16_t l = static_cast<int16_t>(next_sample_idx);
            int16_t r = static_cast<int16_t>(-static_cast<int>(next_sample_idx));
            env.dut->apf_audio_bus_wr = 1;
            env.dut->apf_audio_bus_out = (static_cast<uint32_t>(static_cast<uint16_t>(l)) << 16) |
                                          static_cast<uint16_t>(r);
            next_sample_idx++;
        } else {
            env.dut->apf_audio_bus_wr = 0;
        }
        env.tick();
    }
    env.dut->apf_audio_bus_wr = 0;

    const uint32_t samples_in_10ms = static_cast<uint32_t>(env.popped_audio.size() - base_popped);
    check_eq("Exact 48.000 kHz samples in 10 ms (625,000 cycles)", samples_in_10ms, 480u);

    // Verify sample sequence integrity (strictly sequential 1, 2, 3, ... with zero drops or duplicates)
    for (size_t i = 0; i < env.popped_audio.size(); i++) {
        uint32_t idx = static_cast<uint32_t>(i + 1);
        int16_t exp_l = static_cast<int16_t>(idx);
        int16_t exp_r = static_cast<int16_t>(-static_cast<int>(idx));
        uint32_t exp = (static_cast<uint32_t>(static_cast<uint16_t>(exp_l)) << 16) |
                        static_cast<uint16_t>(exp_r);
        check_eq("Audio FIFO sample sequence", env.popped_audio[i], exp);
    }

    // =========================================================================
    // Test 7: commandCore (FileGetSize, FileRead, FileWrite, FileFlush)
    //         with concurrent host_mem DMA into SDRAM & SRAM!
    // =========================================================================
    std::printf("[7/7] Testing commandCore (FileGetSize, FileRead, FileWrite, FileFlush) with concurrent host_mem DMA...\n");

    // 7a. FileGetSize(0) -> returns 64 MiB (0x04000000)
    uint32_t trig0 = env.complete_trig_count;
    env.dut->apf_bridge_slot_id = 0;
    env.dut->apf_bridge_request_getfile = 1;
    env.tick();
    env.dut->apf_bridge_request_getfile = 0;
    env.tick();
    check_eq("commandCore_request on FileGetSize", env.dut->host_commandCore_request, 1u);
    check_eq("FileGetSize opcode", env.host_read32(0xF0001000u), 0x0400u);
    check_eq("FileGetSize file_id", env.host_read32(0xF0001004u), 0u);

    env.dut->host_commandCore_busy = 1;
    env.host_write32(0xF0001000u, 0u);          // FileStatusOk
    env.host_write32(0xF0001004u, 0x04000000u); // 64 MiB
    env.host_write32(0xF0001008u, 0u);
    env.dut->host_commandCore_done = 1;
    while (env.dut->host_commandCore_request) env.tick();
    env.dut->host_commandCore_busy = 0;
    env.dut->host_commandCore_done = 0;
    env.tick();
    env.tick();
    check_eq("FileGetSize complete_trigger", env.complete_trig_count, trig0 + 1);
    check_eq("FileGetSize result_code", env.dut->apf_bridge_command_result_code, 0u);
    check_eq("FileGetSize updated slot_file_size[0]", env.dut->apf_bridge_file_size, 0x04000000u);

    // 7b. FileRead(0) at offset 0 -> 0x4010_0000 (mapped to 0x0010_0000), .v64 ROM streamed WHILE commandCore_request is high!
    uint32_t inv0 = env.rom_cache_inv_count;
    trig0 = env.complete_trig_count;
    env.dut->apf_bridge_slot_id = 0;
    env.dut->apf_bridge_ram_data_address = 0x40100000u;
    env.dut->apf_bridge_data_offset = 0u;
    env.dut->apf_bridge_length = 16u;
    env.dut->apf_bridge_request_read = 1;
    env.tick();
    env.dut->apf_bridge_request_read = 0;
    env.tick();

    check_eq("commandCore_request on FileRead", env.dut->host_commandCore_request, 1u);
    check_eq("FileRead opcode", env.host_read32(0xF0001000u), 0x0402u);
    check_eq("FileRead file_id", env.host_read32(0xF0001004u), 0u);
    check_eq("FileRead mapped dest", env.host_read32(0xF0001008u), 0x00100000u);
    check_eq("FileRead offset_lo", env.host_read32(0xF000100Cu), 0u);
    check_eq("FileRead length", env.host_read32(0xF0001014u), 16u);

    // Host MCU streams 4 words of .v64 ROM into 0x0010_0000..0x0010_000C while commandCore_request == 1!
    env.dut->host_commandCore_busy = 1;
    env.host_write32(0x00100000u, SimEnv::pack_le(0x37, 0x80, 0x40, 0x12));
    env.host_write32(0x00100004u, SimEnv::pack_le('E', 'Z', 'D', 'L')); // .v64 for "ZELD"
    env.host_write32(0x00100008u, SimEnv::pack_le(0x00, 0x80, 0x04, 0x00));
    env.host_write32(0x0010000Cu, SimEnv::pack_le(0xAD, 0xDE, 0xEF, 0xBE));
    env.host_write32(0xF0001000u, 0u);  // FileStatusOk
    env.host_write32(0xF0001004u, 16u); // 16 bytes read
    env.dut->host_commandCore_done = 1;
    while (env.dut->host_commandCore_request) env.tick();
    env.dut->host_commandCore_busy = 0;
    env.dut->host_commandCore_done = 0;
    env.tick();
    env.tick();

    check_eq("FileRead complete_trigger", env.complete_trig_count, trig0 + 1);
    check_eq("FileRead rom_cache_inv pulsed", env.rom_cache_inv_count, inv0 + 1);
    check_eq("On-demand .v64 word 0", env.sdram[0x040000], 0x80371240u);
    check_eq("On-demand .v64 word 1 ('ZELD')", env.sdram[0x040001], 0x5A454C44u);
    check_eq("On-demand .v64 word 3 (0xDEADBEEF)", env.sdram[0x040003], 0xDEADBEEFu);

    // 7c. FileWrite(1) from SRAM 0x3414_0000 while commandCore_request is high, followed by FileFlush(1)
    trig0 = env.complete_trig_count;
    env.sram[0x10000] = 0xCAFEBABEu;
    env.dut->apf_bridge_slot_id = 1;
    env.dut->apf_bridge_ram_data_address = 0x34140000u;
    env.dut->apf_bridge_data_offset = 64u;
    env.dut->apf_bridge_length = 4u;
    env.dut->apf_bridge_request_write = 1;
    env.tick();
    env.dut->apf_bridge_request_write = 0;
    env.tick();

    check_eq("FileWrite opcode", env.host_read32(0xF0001000u), 0x0403u);
    check_eq("FileWrite src SRAM addr", env.host_read32(0xF0001008u), 0x34140000u);
    check_eq("FileWrite offset", env.host_read32(0xF000100Cu), 64u);
    uint32_t dma_read = env.host_read32(0x34140000u);
    check_eq("Host DMA read from SRAM during FileWrite", dma_read, SimEnv::pack_le(0xCA, 0xFE, 0xBA, 0xBE));
    env.host_write32(0xF0001000u, 0u);
    env.host_write32(0xF0001004u, 4u);
    env.dut->host_commandCore_done = 1;
    while (env.dut->host_commandCore_request) env.tick();
    env.dut->host_commandCore_done = 0;
    env.tick();
    env.tick();
    check_eq("FileWrite complete_trigger", env.complete_trig_count, trig0 + 1);

    // FileFlush(1)
    trig0 = env.complete_trig_count;
    env.dut->apf_bridge_slot_id = 1;
    env.dut->apf_bridge_request_flush = 1;
    env.tick();
    env.dut->apf_bridge_request_flush = 0;
    env.tick();
    check_eq("FileFlush opcode", env.host_read32(0xF0001000u), 0x0404u);
    check_eq("FileFlush file_id", env.host_read32(0xF0001004u), 1u);
    env.host_write32(0xF0001000u, 0u);
    env.dut->host_commandCore_done = 1;
    while (env.dut->host_commandCore_request) env.tick();
    env.dut->host_commandCore_done = 0;
    env.tick();
    env.tick();
    check_eq("FileFlush complete_trigger", env.complete_trig_count, trig0 + 1);

    std::printf("ALL gb_host_bridge TESTS PASSED!\n");
    return 0;
}
