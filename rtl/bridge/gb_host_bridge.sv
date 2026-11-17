// Game Bub Host Bridge (Workstream B)
// Connects Game Bub's HostV0, InputExtendedV0(4), VibrateV0, and AudioV0
// interfaces to Mirlo's MIPS SoC (mirlo_mips / mirlo_regs) and external
// SDRAM (64 MiB) + SRAM (512 KiB) ports.
`default_nettype none

module gb_host_bridge #(
    parameter bit DIAG_L3_RUMBLE = 1'b0
) (
    input  wire logic        clk,
    input  wire logic        rst,

    // External memory initialization status
    input  wire logic        sdr_ready,
    input  wire logic        sram_ready,

    // Game Bub HostV0: Memory interface
    input  wire logic        host_mem_enable,
    input  wire logic        host_mem_write,
    output logic             host_mem_done,
    input  wire logic [31:0] host_mem_address,
    output logic      [31:0] host_mem_dataRead,
    input  wire logic [31:0] host_mem_dataWrite,

    // Game Bub HostV0: Host -> Core command channel (0xF000_0000..0xF000_001F)
    input  wire logic        host_commandHost_request,
    output logic             host_commandHost_busy,
    output logic             host_commandHost_done,
    output logic             host_commandHost_error,

    // Game Bub HostV0: Core -> Host command channel (0xF000_1000..0xF000_101F)
    output logic             host_commandCore_request,
    input  wire logic        host_commandCore_busy,
    input  wire logic        host_commandCore_done,
    input  wire logic        host_commandCore_error,

    // Game Bub InputExtendedV0 (4 controller slots)
    input  wire logic        input_slots_0_active,
    input  wire logic [3:0]  input_slots_0_deviceType,
    input  wire logic        input_slots_0_buttons_a,
    input  wire logic        input_slots_0_buttons_b,
    input  wire logic        input_slots_0_buttons_x,
    input  wire logic        input_slots_0_buttons_y,
    input  wire logic        input_slots_0_buttons_up,
    input  wire logic        input_slots_0_buttons_down,
    input  wire logic        input_slots_0_buttons_left,
    input  wire logic        input_slots_0_buttons_right,
    input  wire logic        input_slots_0_buttons_l1,
    input  wire logic        input_slots_0_buttons_r1,
    input  wire logic        input_slots_0_buttons_l2,
    input  wire logic        input_slots_0_buttons_r2,
    input  wire logic        input_slots_0_buttons_l3,
    input  wire logic        input_slots_0_buttons_r3,
    input  wire logic        input_slots_0_buttons_start,
    input  wire logic        input_slots_0_buttons_select,
    input  wire logic [7:0]  input_slots_0_analog_leftX,
    input  wire logic [7:0]  input_slots_0_analog_leftY,
    input  wire logic [7:0]  input_slots_0_analog_rightX,
    input  wire logic [7:0]  input_slots_0_analog_rightY,
    input  wire logic [7:0]  input_slots_0_analog_leftTrigger,
    input  wire logic [7:0]  input_slots_0_analog_rightTrigger,

    input  wire logic        input_slots_1_active,
    input  wire logic [3:0]  input_slots_1_deviceType,
    input  wire logic        input_slots_1_buttons_a,
    input  wire logic        input_slots_1_buttons_b,
    input  wire logic        input_slots_1_buttons_x,
    input  wire logic        input_slots_1_buttons_y,
    input  wire logic        input_slots_1_buttons_up,
    input  wire logic        input_slots_1_buttons_down,
    input  wire logic        input_slots_1_buttons_left,
    input  wire logic        input_slots_1_buttons_right,
    input  wire logic        input_slots_1_buttons_l1,
    input  wire logic        input_slots_1_buttons_r1,
    input  wire logic        input_slots_1_buttons_l2,
    input  wire logic        input_slots_1_buttons_r2,
    input  wire logic        input_slots_1_buttons_l3,
    input  wire logic        input_slots_1_buttons_r3,
    input  wire logic        input_slots_1_buttons_start,
    input  wire logic        input_slots_1_buttons_select,
    input  wire logic [7:0]  input_slots_1_analog_leftX,
    input  wire logic [7:0]  input_slots_1_analog_leftY,
    input  wire logic [7:0]  input_slots_1_analog_rightX,
    input  wire logic [7:0]  input_slots_1_analog_rightY,
    input  wire logic [7:0]  input_slots_1_analog_leftTrigger,
    input  wire logic [7:0]  input_slots_1_analog_rightTrigger,

    input  wire logic        input_slots_2_active,
    input  wire logic [3:0]  input_slots_2_deviceType,
    input  wire logic        input_slots_2_buttons_a,
    input  wire logic        input_slots_2_buttons_b,
    input  wire logic        input_slots_2_buttons_x,
    input  wire logic        input_slots_2_buttons_y,
    input  wire logic        input_slots_2_buttons_up,
    input  wire logic        input_slots_2_buttons_down,
    input  wire logic        input_slots_2_buttons_left,
    input  wire logic        input_slots_2_buttons_right,
    input  wire logic        input_slots_2_buttons_l1,
    input  wire logic        input_slots_2_buttons_r1,
    input  wire logic        input_slots_2_buttons_l2,
    input  wire logic        input_slots_2_buttons_r2,
    input  wire logic        input_slots_2_buttons_l3,
    input  wire logic        input_slots_2_buttons_r3,
    input  wire logic        input_slots_2_buttons_start,
    input  wire logic        input_slots_2_buttons_select,
    input  wire logic [7:0]  input_slots_2_analog_leftX,
    input  wire logic [7:0]  input_slots_2_analog_leftY,
    input  wire logic [7:0]  input_slots_2_analog_rightX,
    input  wire logic [7:0]  input_slots_2_analog_rightY,
    input  wire logic [7:0]  input_slots_2_analog_leftTrigger,
    input  wire logic [7:0]  input_slots_2_analog_rightTrigger,

    input  wire logic        input_slots_3_active,
    input  wire logic [3:0]  input_slots_3_deviceType,
    input  wire logic        input_slots_3_buttons_a,
    input  wire logic        input_slots_3_buttons_b,
    input  wire logic        input_slots_3_buttons_x,
    input  wire logic        input_slots_3_buttons_y,
    input  wire logic        input_slots_3_buttons_up,
    input  wire logic        input_slots_3_buttons_down,
    input  wire logic        input_slots_3_buttons_left,
    input  wire logic        input_slots_3_buttons_right,
    input  wire logic        input_slots_3_buttons_l1,
    input  wire logic        input_slots_3_buttons_r1,
    input  wire logic        input_slots_3_buttons_l2,
    input  wire logic        input_slots_3_buttons_r2,
    input  wire logic        input_slots_3_buttons_l3,
    input  wire logic        input_slots_3_buttons_r3,
    input  wire logic        input_slots_3_buttons_start,
    input  wire logic        input_slots_3_buttons_select,
    input  wire logic [7:0]  input_slots_3_analog_leftX,
    input  wire logic [7:0]  input_slots_3_analog_leftY,
    input  wire logic [7:0]  input_slots_3_analog_rightX,
    input  wire logic [7:0]  input_slots_3_analog_rightY,
    input  wire logic [7:0]  input_slots_3_analog_leftTrigger,
    input  wire logic [7:0]  input_slots_3_analog_rightTrigger,

    // VibrateV0 + Rumble state from mirlo_regs INTERACT2[30]
    input  wire logic        rumble_motor_on,
    output wire logic [1:0]  vibrate_mode,

    // AudioV0 (signed 16-bit stereo @ exact 48,000 Hz)
    output logic signed [15:0] audio_left,
    output logic signed [15:0] audio_right,

    // Mirlo SoC audio FIFO interface
    output wire logic [11:0] apf_audio_buffer_fill,
    input  wire logic [31:0] apf_audio_bus_out,
    input  wire logic        apf_audio_bus_wr,
    input  wire logic        apf_audio_flush,
    input  wire logic        apf_audio_playback_en,

    // Mirlo SoC bridge CSR interface
    output logic      [2:0]  apf_bridge_command_result_code,
    output logic             apf_bridge_complete_trigger,
    output logic      [31:0] apf_bridge_current_address,
    input  wire logic [31:0] apf_bridge_data_offset,
    output wire logic [31:0] apf_bridge_file_size,
    input  wire logic        apf_bridge_file_size_wr,
    output logic             apf_bridge_host_loaded,
    output wire logic        apf_bridge_host_reset_n,
    input  wire logic [31:0] apf_bridge_length,
    input  wire logic [31:0] apf_bridge_new_file_size_data,
    input  wire logic [31:0] apf_bridge_ram_data_address,
    input  wire logic        apf_bridge_request_getfile,
    input  wire logic        apf_bridge_request_openfile,
    input  wire logic        apf_bridge_request_read,
    input  wire logic        apf_bridge_request_write,
    input  wire logic        apf_bridge_request_setsize,
    input  wire logic        apf_bridge_request_flush,
    input  wire logic [15:0] apf_bridge_slot_id,

    // Mirlo SoC pad RAM scanner interface
    output wire logic        apf_pad_clk,
    output logic             apf_pad_we,
    output logic      [3:0]  apf_pad_wa,
    output logic      [31:0] apf_pad_wd,

    // Mirlo SoC interact CSR interface
    output logic      [4:0]  apf_interact_address,
    output logic      [31:0] apf_interact_data,
    output logic             apf_interact_wr,

    // Bridge SDRAM master port (0x0000_0000..0x03FF_FFFF -> word 24'h00_0000..24'hFF_FFFF)
    output logic             br_sdr_valid,
    output logic             br_sdr_we,
    output logic      [23:0] br_sdr_addr,
    output logic      [31:0] br_sdr_wdata,
    output logic      [3:0]  br_sdr_be,
    input  wire logic        br_sdr_ready,
    input  wire logic        br_sdr_rvalid,
    input  wire logic [31:0] br_sdr_rdata,
    output wire logic        br_sdr_pending,

    // Bridge SRAM master port (0x3410_0000..0x3417_FFFF -> word 17'h00000..17'h1FFFF)
    output logic             h_sram_valid,
    output logic             h_sram_we,
    output logic      [16:0] h_sram_addr,
    output logic      [31:0] h_sram_wdata,
    output logic      [3:0]  h_sram_be,
    input  wire logic        h_sram_ack,
    input  wire logic [31:0] h_sram_rdata,

    // Exported lifecycle & decoded configuration signals
    output logic             setup_done,
    output logic             core_running,
    output logic             core_focused,
    output logic             rom_cache_inv,
    output wire logic        vid_horiz_blend_en,
    output wire logic        vid_dither_en,
    output wire logic        vid_no_weave,
    output wire logic [1:0]  vid_fps_mode,
    output wire logic signed [7:0] sdram_ps_target
);

    // =========================================================================
    // Constants: HostV0 Commands & Status Codes
    // =========================================================================
    localparam logic [15:0] CMD_GET_STATUS       = 16'h0000;
    localparam logic [15:0] CMD_CORE_RUN         = 16'h0100;
    localparam logic [15:0] CMD_CORE_HALT        = 16'h0101;
    localparam logic [15:0] CMD_SETUP_COMPLETE   = 16'h0102;
    localparam logic [15:0] CMD_NOTIFY_FOCUS     = 16'h0200;
    localparam logic [15:0] CMD_FILE_WRITE_START = 16'h0300;
    localparam logic [15:0] CMD_FILE_WRITE_END   = 16'h0301;
    localparam logic [15:0] CMD_FILE_READ_START  = 16'h0302;
    localparam logic [15:0] CMD_FILE_READ_END    = 16'h0303;

    localparam logic [31:0] CMD_CORE_GET_SIZE    = 32'h0000_0400;
    localparam logic [31:0] CMD_CORE_SET_SIZE    = 32'h0000_0401;
    localparam logic [31:0] CMD_CORE_READ        = 32'h0000_0402;
    localparam logic [31:0] CMD_CORE_WRITE       = 32'h0000_0403;
    localparam logic [31:0] CMD_CORE_FLUSH       = 32'h0000_0404;

    localparam logic [31:0] STATUS_INITIALIZE    = 32'd1;
    localparam logic [31:0] STATUS_SETUP         = 32'd2;
    localparam logic [31:0] STATUS_CORE_HALT     = 32'd3;
    localparam logic [31:0] STATUS_CORE_RUN      = 32'd4;

    wire mem_ready = sdr_ready && sram_ready;
    assign apf_bridge_host_reset_n = core_running && setup_done;

    // =========================================================================
    // Helper Functions: Byte-Swapping & ROM Endianness Detection
    // =========================================================================
    function automatic logic [31:0] bswap32(input logic [31:0] w);
        return {w[7:0], w[15:8], w[23:16], w[31:24]};
    endfunction

    function automatic logic [1:0] detect_rom_swap(input logic [31:0] w);
        case (w)
            32'h4012_3780: return 2'd0; // .z64 [80, 37, 12, 40] on LE host -> byte swap
            32'h1240_8037: return 2'd1; // .v64 [37, 80, 40, 12] on LE host -> halfword swap
            32'h8037_1240: return 2'd2; // .n64 [40, 12, 37, 80] on LE host -> word pass-through
            default:       return 2'd0; // non-ROM MIPS binary / default -> byte swap
        endcase
    endfunction

    function automatic logic [31:0] apply_rom_swap(input logic [31:0] w, input logic [1:0] mode);
        case (mode)
            2'd1:    return {w[15:0], w[31:16]};
            2'd2:    return w;
            default: return bswap32(w);
        endcase
    endfunction

    // =========================================================================
    // Register Banks: commandHost, commandCore, settings.json, slot_file_size
    // =========================================================================
    logic [31:0] cmd_host_reg [0:7];
    logic [31:0] cmd_core_reg [0:7];
    logic [31:0] cfg_reg      [0:15];
    logic [31:0] cfg_fps_reg;
    logic [31:0] slot_file_size [0:15];

    assign apf_bridge_file_size = (apf_bridge_slot_id < 16'd16) ? slot_file_size[apf_bridge_slot_id[3:0]] : 32'd0;

    assign vid_horiz_blend_en = !cfg_reg[8][0];
    assign vid_dither_en      = !cfg_reg[8][1];
    assign vid_no_weave       = cfg_reg[8][2];
    assign vid_fps_mode       = cfg_fps_reg[1:0];
    assign sdram_ps_target    = $signed(cfg_reg[11][7:0]);

    // =========================================================================
    // 1. HostV0 Memory Bus + Lifecycle (commandHost) + On-Demand (commandCore)
    // =========================================================================
    typedef enum logic [2:0] {
        HM_IDLE,
        HM_SDR_REQ,
        HM_SDR_WAIT,
        HM_SRAM_REQ
    } hm_state_t;
    hm_state_t hm_state;

    typedef enum logic [1:0] {
        CH_IDLE,
        CH_BUSY,
        CH_DONE
    } ch_state_t;
    ch_state_t ch_state;

    typedef enum logic [1:0] {
        CC_IDLE,
        CC_REQ,
        CC_DROP
    } cc_state_t;
    cc_state_t cc_state;

    typedef enum logic [2:0] {
        CC_OP_GETSIZE = 3'd0,
        CC_OP_SETSIZE = 3'd1,
        CC_OP_READ    = 3'd2,
        CC_OP_WRITE   = 3'd3,
        CC_OP_FLUSH   = 3'd4
    } cc_op_t;
    cc_op_t      cc_op;
    logic [15:0] cc_slot;
    logic [31:0] cc_dest;
    logic [31:0] cc_off;
    logic [31:0] cc_new_size;

    logic        writing_file;
    logic [15:0] active_write_id;
    logic        non_ff_seen;
    logic [1:0]  rom_swap_mode;
    logic        core_has_run;

    assign host_commandHost_busy    = (ch_state == CH_BUSY);
    assign host_commandHost_done    = (ch_state == CH_DONE);
    assign host_commandHost_error   = 1'b0;
    assign host_commandCore_request = (cc_state == CC_REQ);

    // Map Mirlo's apf_bridge_ram_data_address into Game Bub core host.mem space:
    //   SRAM  0x3410_0000..0x3417_FFFF -> 0x3410_0000..0x3417_FFFF
    //   SDRAM 0x0000_0000..0x03FF_FFFF or 0x4000_0000..0x43FF_FFFF -> 0x0000_0000..0x03FF_FFFF
    wire [31:0] mapped_ram_addr = (apf_bridge_ram_data_address[31:21] == 11'h1A0)
                                ? apf_bridge_ram_data_address
                                : {6'd0, apf_bridge_ram_data_address[25:0]};

    wire hm_start    = (hm_state == HM_IDLE) && host_mem_enable && !host_mem_done;
    wire hm_is_sdr   = (host_mem_address[31:26] == 6'd0);                           // 0x0000_0000..0x03FF_FFFF
    wire hm_is_sram  = (host_mem_address >= 32'h3410_0000) && (host_mem_address < 32'h3418_0000);
    wire hm_is_cfg   = (host_mem_address[31:6] == 26'h1C0_0000);                    // 0x7000_0000..0x7000_003F
    wire hm_is_cfgx  = (host_mem_address == 32'h7000_0040);                         // 0x7000_0040 (FPS Counter)
    wire hm_is_cmdh  = (host_mem_address[31:5] == 27'h780_0000);                    // 0xF000_0000..0xF000_001F
    wire hm_is_cmdc  = (host_mem_address[31:5] == 27'h780_0080);                    // 0xF000_1000..0xF000_101F

    // ROM region in SDRAM: 0x0010_0000..0x03FF_FFFF (or active FileWrite/FileRead for File ID 0)
    wire hm_is_rom   = (host_mem_address >= 32'h0010_0000 && host_mem_address < 32'h0400_0000) ||
                       (writing_file && active_write_id == 16'd0) ||
                       (cc_state == CC_REQ && cc_op == CC_OP_READ && cc_slot == 16'd0);
    wire hm_is_rom0  = (host_mem_address == 32'h0010_0000) ||
                       (cc_state == CC_REQ && cc_op == CC_OP_READ && cc_slot == 16'd0 &&
                        cc_off == 32'd0 && host_mem_address == cc_dest);
    wire [1:0] eff_rom_swap = hm_is_rom0 ? detect_rom_swap(host_mem_dataWrite) : rom_swap_mode;

    assign br_sdr_pending = (hm_state == HM_SDR_REQ) || (hm_state == HM_SDR_WAIT) || (hm_start && hm_is_sdr);

    always_ff @(posedge clk) begin
        if (rst) begin
            hm_state          <= HM_IDLE;
            host_mem_done     <= 1'b0;
            host_mem_dataRead <= 32'd0;

            br_sdr_valid      <= 1'b0;
            br_sdr_we         <= 1'b0;
            br_sdr_addr       <= 24'd0;
            br_sdr_wdata      <= 32'd0;
            br_sdr_be         <= 4'hF;

            h_sram_valid      <= 1'b0;
            h_sram_we         <= 1'b0;
            h_sram_addr       <= 17'd0;
            h_sram_wdata      <= 32'd0;
            h_sram_be         <= 4'hF;

            ch_state          <= CH_IDLE;
            cc_state          <= CC_IDLE;
            cc_op             <= CC_OP_GETSIZE;
            cc_slot           <= 16'd0;
            cc_dest           <= 32'd0;
            cc_off            <= 32'd0;
            cc_new_size       <= 32'd0;

            setup_done        <= 1'b0;
            core_running      <= 1'b0;
            core_has_run      <= 1'b0;
            core_focused      <= 1'b0;
            writing_file      <= 1'b0;
            active_write_id   <= 16'd0;
            non_ff_seen       <= 1'b0;
            rom_swap_mode     <= 2'd0;
            rom_cache_inv     <= 1'b0;

            apf_bridge_host_loaded         <= 1'b0;
            apf_bridge_complete_trigger    <= 1'b0;
            apf_bridge_command_result_code <= 3'd0;
            apf_bridge_current_address     <= 32'd0;

            apf_interact_wr      <= 1'b0;
            apf_interact_address <= 5'd0;
            apf_interact_data    <= 32'd0;

            for (int i = 0; i < 8; i++) begin
                cmd_host_reg[i] <= 32'd0;
                cmd_core_reg[i] <= 32'd0;
            end
            for (int i = 0; i < 16; i++) begin
                cfg_reg[i]        <= 32'd0;
                slot_file_size[i] <= 32'd0;
            end
            cfg_fps_reg <= 32'd0;
            // Match metadata/settings.json defaults
            cfg_reg[0] <= 32'd1; // Controller 1 Pak = Controller Pak
            cfg_reg[1] <= 32'd1; // Handheld R Mode = R + ABXY = C-Btns
            cfg_reg[2] <= 32'd1; // Analog Stick = L-Stick / D-Pad
            cfg_reg[3] <= 32'd1; // C-Buttons Extra = Right Stick
        end else begin
            // Default 1-cycle pulses
            host_mem_done               <= 1'b0;
            rom_cache_inv               <= 1'b0;
            apf_bridge_complete_trigger <= 1'b0;
            apf_interact_wr             <= 1'b0;

            // SoC CPU updating nonvolatile file size table
            if (apf_bridge_file_size_wr && apf_bridge_slot_id < 16'd16) begin
                slot_file_size[apf_bridge_slot_id[3:0]] <= apf_bridge_new_file_size_data;
            end

            // -----------------------------------------------------------------
            // A. Host Memory Interface FSM (remains 100% active during CC_REQ!)
            // -----------------------------------------------------------------
            case (hm_state)
                HM_IDLE: begin
                    if (hm_start) begin
                        if (hm_is_sdr) begin
                            apf_bridge_current_address <= host_mem_address;
                            if (host_mem_write && writing_file && host_mem_dataWrite != 32'hFFFF_FFFF)
                                non_ff_seen <= 1'b1;
                            if (host_mem_write && hm_is_rom0)
                                rom_swap_mode <= eff_rom_swap;

                            br_sdr_valid <= 1'b1;
                            br_sdr_we    <= host_mem_write;
                            br_sdr_addr  <= host_mem_address[25:2];
                            br_sdr_be    <= 4'hF;
                            br_sdr_wdata <= hm_is_rom ? apply_rom_swap(host_mem_dataWrite, eff_rom_swap)
                                                      : bswap32(host_mem_dataWrite);
                            hm_state     <= HM_SDR_REQ;
                        end else if (hm_is_sram) begin
                            apf_bridge_current_address <= host_mem_address;
                            if (host_mem_write && writing_file && host_mem_dataWrite != 32'hFFFF_FFFF)
                                non_ff_seen <= 1'b1;

                            h_sram_valid <= 1'b1;
                            h_sram_we    <= host_mem_write;
                            h_sram_addr  <= host_mem_address[18:2];
                            h_sram_be    <= 4'hF;
                            h_sram_wdata <= bswap32(host_mem_dataWrite);
                            hm_state     <= HM_SRAM_REQ;
                        end else if (hm_is_cfg) begin
                            automatic logic [3:0] cidx = host_mem_address[5:2];
                            if (host_mem_write) begin
                                cfg_reg[cidx] <= host_mem_dataWrite;
                                case (cidx)
                                    4'd0: begin // Controller 1 Pak -> INTERACT0[4:0]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd2;
                                        apf_interact_data    <= {27'd0, host_mem_dataWrite[4:0]};
                                    end
                                    4'd1: begin // Handheld R Modifier -> INTERACT0[14:10]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd4;
                                        apf_interact_data    <= {27'd0, host_mem_dataWrite[4:0]};
                                    end
                                    4'd2: begin // Stick Source -> INTERACT1[19:15]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd11;
                                        apf_interact_data    <= {27'd0, host_mem_dataWrite[4:0]};
                                    end
                                    4'd3: begin // C-Buttons Extra -> INTERACT1[14:10]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd10;
                                        apf_interact_data    <= {27'd0, host_mem_dataWrite[4:0]};
                                    end
                                    4'd4: begin // Stick Deadzone -> INTERACT1[9:5]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd9;
                                        apf_interact_data    <= {27'd0, host_mem_dataWrite[4:0]};
                                    end
                                    4'd5: begin // Expansion Pak Disable (4MB Only) -> INTERACT1[24]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd14;
                                        apf_interact_data    <= {31'd0, host_mem_dataWrite[0]};
                                    end
                                    4'd6: begin // VI Deblur -> INTERACT2[6] (field 17 = INTERACT2[9:5])
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd17;
                                        apf_interact_data    <= {30'd0, host_mem_dataWrite[0], cfg_reg[7][0]};
                                    end
                                    4'd7: begin // 32-bit Output -> INTERACT2[5] (field 17 = INTERACT2[9:5])
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd17;
                                        apf_interact_data    <= {30'd0, cfg_reg[6][0], host_mem_dataWrite[0]};
                                    end
                                    4'd9: begin // Crop Vertical -> INTERACT0[9:5]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd3;
                                        apf_interact_data    <= {27'd0, host_mem_dataWrite[4:0]};
                                    end
                                    4'd10: begin // Restart Game action -> INTERACT1[21:20]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd12;
                                        apf_interact_data    <= {30'd0, host_mem_dataWrite[1:0]};
                                    end
                                    4'd12: begin // D-Pad Source -> INTERACT1[23:22]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd13;
                                        apf_interact_data    <= {30'd0, host_mem_dataWrite[1:0]};
                                    end
                                    4'd13: begin // Crop Horizontal -> INTERACT0[19:15]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd5;
                                        apf_interact_data    <= {27'd0, host_mem_dataWrite[4:0]};
                                    end
                                    4'd14: begin // Start Button -> INTERACT1[4:0]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd8;
                                        apf_interact_data    <= {27'd0, host_mem_dataWrite[4:0]};
                                    end
                                    4'd15: begin // GameShark -> INTERACT1[25]
                                        apf_interact_wr      <= 1'b1;
                                        apf_interact_address <= 5'd15;
                                        apf_interact_data    <= {31'd0, host_mem_dataWrite[0]};
                                    end
                                    default: ; // 8 (vid filter), 11 (sdram_ps_target) exported directly
                                endcase
                            end else begin
                                host_mem_dataRead <= cfg_reg[cidx];
                            end
                            host_mem_done <= 1'b1;
                        end else if (hm_is_cfgx) begin
                            if (host_mem_write)
                                cfg_fps_reg <= host_mem_dataWrite;
                            else
                                host_mem_dataRead <= cfg_fps_reg;
                            host_mem_done <= 1'b1;
                        end else if (hm_is_cmdh) begin
                            if (host_mem_write)
                                cmd_host_reg[host_mem_address[4:2]] <= host_mem_dataWrite;
                            else
                                host_mem_dataRead <= cmd_host_reg[host_mem_address[4:2]];
                            host_mem_done <= 1'b1;
                        end else if (hm_is_cmdc) begin
                            if (host_mem_write)
                                cmd_core_reg[host_mem_address[4:2]] <= host_mem_dataWrite;
                            else
                                host_mem_dataRead <= cmd_core_reg[host_mem_address[4:2]];
                            host_mem_done <= 1'b1;
                        end else begin
                            host_mem_dataRead <= 32'd0;
                            host_mem_done     <= 1'b1;
                        end
                    end
                end

                HM_SDR_REQ: begin
                    if (br_sdr_ready) begin
                        br_sdr_valid <= 1'b0;
                        if (br_sdr_we) begin
                            host_mem_done <= 1'b1;
                            hm_state      <= HM_IDLE;
                        end else if (br_sdr_rvalid) begin
                            host_mem_dataRead <= bswap32(br_sdr_rdata);
                            host_mem_done     <= 1'b1;
                            hm_state          <= HM_IDLE;
                        end else begin
                            hm_state <= HM_SDR_WAIT;
                        end
                    end
                end

                HM_SDR_WAIT: begin
                    if (br_sdr_rvalid) begin
                        host_mem_dataRead <= bswap32(br_sdr_rdata);
                        host_mem_done     <= 1'b1;
                        hm_state          <= HM_IDLE;
                    end
                end

                HM_SRAM_REQ: begin
                    if (h_sram_ack) begin
                        h_sram_valid <= 1'b0;
                        if (!h_sram_we)
                            host_mem_dataRead <= bswap32(h_sram_rdata);
                        host_mem_done <= 1'b1;
                        hm_state      <= HM_IDLE;
                    end
                end

                default: hm_state <= HM_IDLE;
            endcase

            // -----------------------------------------------------------------
            // B. Host -> Core Command Channel (commandHost)
            // -----------------------------------------------------------------
            case (ch_state)
                CH_IDLE: begin
                    if (host_commandHost_request)
                        ch_state <= CH_BUSY;
                end

                CH_BUSY: begin
                    ch_state <= CH_DONE;
                    case (cmd_host_reg[0][15:0])
                        CMD_GET_STATUS: begin
                            if (!mem_ready)
                                cmd_host_reg[0] <= STATUS_INITIALIZE;
                            else if (!setup_done)
                                cmd_host_reg[0] <= STATUS_SETUP;
                            else if (!core_running)
                                cmd_host_reg[0] <= STATUS_CORE_HALT;
                            else
                                cmd_host_reg[0] <= STATUS_CORE_RUN;
                        end

                        CMD_SETUP_COMPLETE: begin
                            setup_done             <= 1'b1;
                            apf_bridge_host_loaded <= 1'b1;
                            cmd_host_reg[0]        <= 32'd0;
                        end

                        CMD_CORE_RUN: begin
                            if (!core_running && core_has_run) begin
                                // Host issued CoreHalt -> CoreRun ("Reset Game"): trigger n64rt clean soft restart
                                apf_interact_wr      <= 1'b1;
                                apf_interact_address <= 5'd12;
                                apf_interact_data    <= 32'd1;
                            end
                            core_running    <= 1'b1;
                            core_has_run    <= 1'b1;
                            cmd_host_reg[0] <= 32'd0;
                        end

                        CMD_CORE_HALT: begin
                            core_running    <= 1'b0;
                            cmd_host_reg[0] <= 32'd0;
                        end

                        CMD_NOTIFY_FOCUS: begin
                            core_focused    <= cmd_host_reg[1][0];
                            cmd_host_reg[0] <= 32'd0;
                        end

                        CMD_FILE_WRITE_START: begin
                            writing_file    <= 1'b1;
                            active_write_id <= cmd_host_reg[1][15:0];
                            non_ff_seen     <= 1'b0;
                            if (cmd_host_reg[1][15:0] == 16'd0) begin
                                rom_cache_inv <= 1'b1;
                                rom_swap_mode <= 2'd0;
                                core_has_run  <= 1'b0;
                            end else if (cmd_host_reg[1][15:0] == 16'd3) begin
                                core_has_run  <= 1'b0;
                            end
                            cmd_host_reg[0] <= 32'd0;
                        end

                        CMD_FILE_WRITE_END: begin
                            automatic logic [15:0] fid  = cmd_host_reg[1][15:0];
                            automatic logic [31:0] fsz  = cmd_host_reg[2];
                            writing_file <= 1'b0;
                            if (fid < 16'd16) begin
                                if ((fid == 16'd1 || fid == 16'd2) && !non_ff_seen)
                                    slot_file_size[fid[3:0]] <= 32'd0;
                                else
                                    slot_file_size[fid[3:0]] <= fsz;
                            end
                            if (fid == 16'd0)
                                rom_cache_inv <= 1'b1;
                            cmd_host_reg[0] <= 32'd0;
                        end

                        CMD_FILE_READ_START: begin
                            automatic logic [15:0] fid = cmd_host_reg[1][15:0];
                            cmd_host_reg[0] <= (fid < 16'd16) ? slot_file_size[fid[3:0]] : 32'd0;
                        end

                        CMD_FILE_READ_END: begin
                            cmd_host_reg[0] <= 32'd0;
                        end

                        default: begin
                            cmd_host_reg[0] <= 32'd0;
                        end
                    endcase
                end

                CH_DONE: begin
                    if (!host_commandHost_request)
                        ch_state <= CH_IDLE;
                end

                default: ch_state <= CH_IDLE;
            endcase

            // -----------------------------------------------------------------
            // C. Core -> Host Command Channel (commandCore: Phase-5 On-Demand)
            // -----------------------------------------------------------------
            case (cc_state)
                CC_IDLE: begin
                    if (!host_commandCore_done && !host_commandCore_busy) begin
                        if (apf_bridge_request_getfile) begin
                            cmd_core_reg[0] <= CMD_CORE_GET_SIZE;
                            cmd_core_reg[1] <= {16'd0, apf_bridge_slot_id};
                            cmd_core_reg[2] <= 32'd0;
                            cc_op           <= CC_OP_GETSIZE;
                            cc_slot         <= apf_bridge_slot_id;
                            cc_state        <= CC_REQ;
                        end else if (apf_bridge_request_setsize) begin
                            cmd_core_reg[0] <= CMD_CORE_SET_SIZE;
                            cmd_core_reg[1] <= {16'd0, apf_bridge_slot_id};
                            cmd_core_reg[2] <= apf_bridge_new_file_size_data;
                            cmd_core_reg[3] <= 32'd0;
                            cc_op           <= CC_OP_SETSIZE;
                            cc_slot         <= apf_bridge_slot_id;
                            cc_new_size     <= apf_bridge_new_file_size_data;
                            cc_state        <= CC_REQ;
                        end else if (apf_bridge_request_read) begin
                            cmd_core_reg[0] <= CMD_CORE_READ;
                            cmd_core_reg[1] <= {16'd0, apf_bridge_slot_id};
                            cmd_core_reg[2] <= mapped_ram_addr;
                            cmd_core_reg[3] <= apf_bridge_data_offset;
                            cmd_core_reg[4] <= 32'd0;
                            cmd_core_reg[5] <= apf_bridge_length;
                            cc_op           <= CC_OP_READ;
                            cc_slot         <= apf_bridge_slot_id;
                            cc_dest         <= mapped_ram_addr;
                            cc_off          <= apf_bridge_data_offset;
                            cc_state        <= CC_REQ;
                        end else if (apf_bridge_request_write) begin
                            cmd_core_reg[0] <= CMD_CORE_WRITE;
                            cmd_core_reg[1] <= {16'd0, apf_bridge_slot_id};
                            cmd_core_reg[2] <= mapped_ram_addr;
                            cmd_core_reg[3] <= apf_bridge_data_offset;
                            cmd_core_reg[4] <= 32'd0;
                            cmd_core_reg[5] <= apf_bridge_length;
                            cc_op           <= CC_OP_WRITE;
                            cc_slot         <= apf_bridge_slot_id;
                            cc_dest         <= mapped_ram_addr;
                            cc_off          <= apf_bridge_data_offset;
                            cc_state        <= CC_REQ;
                        end else if (apf_bridge_request_flush) begin
                            cmd_core_reg[0] <= CMD_CORE_FLUSH;
                            cmd_core_reg[1] <= {16'd0, apf_bridge_slot_id};
                            cc_op           <= CC_OP_FLUSH;
                            cc_slot         <= apf_bridge_slot_id;
                            cc_state        <= CC_REQ;
                        end else if (apf_bridge_request_openfile) begin
                            // Game Bub has no open-by-path command; complete immediately as not-found (3)
                            apf_bridge_command_result_code <= 3'd3;
                            apf_bridge_complete_trigger    <= 1'b1;
                        end
                    end
                end

                CC_REQ: begin
                    if (host_commandCore_done && hm_state == HM_IDLE && !hm_start) begin
                        if (host_commandCore_error || cmd_core_reg[0] != 32'd0) begin
                            apf_bridge_command_result_code <= (cmd_core_reg[0][2:0] != 3'd0) ? cmd_core_reg[0][2:0] : 3'd2;
                        end else begin
                            apf_bridge_command_result_code <= 3'd0;
                            if (cc_op == CC_OP_GETSIZE && cc_slot < 16'd16)
                                slot_file_size[cc_slot[3:0]] <= cmd_core_reg[1];
                            if (cc_op == CC_OP_SETSIZE && cc_slot < 16'd16)
                                slot_file_size[cc_slot[3:0]] <= cc_new_size;
                            if (cc_op == CC_OP_READ && (cc_slot == 16'd0 || (cc_dest >= 32'h0010_0000 && cc_dest < 32'h0400_0000)))
                                rom_cache_inv <= 1'b1;
                        end
                        cc_state <= CC_DROP;
                    end
                end

                CC_DROP: begin
                    // request is now low; once host clears done/busy, pulse complete_trigger
                    if (!host_commandCore_done && !host_commandCore_busy) begin
                        apf_bridge_complete_trigger <= 1'b1;
                        cc_state                    <= CC_IDLE;
                    end
                end

                default: cc_state <= CC_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 2. InputExtendedV0(4) -> apf_pad_* Scanner (wa = 0..11)
    // =========================================================================
    function automatic logic [7:0] joy_u8(input logic [7:0] s);
        // Clamp -128 (8'h80) to -127 (8'h81), then bias to unsigned 0x80 center:
        //   0 -> 0x80, -127 -> 0x01, +127 -> 0xFF
        logic [7:0] clamped;
        clamped = (s == 8'h80) ? 8'h81 : s;
        return clamped ^ 8'h80;
    endfunction

    function automatic logic [31:0] build_key(
        input logic       active,
        input logic [3:0] dev_type,
        input logic       up, down, left, right,
        input logic       a, b, x, y,
        input logic       l1, r1, l2, r2, l3, r3,
        input logic       select_b, start_b,
        input logic [7:0] ltrig, rtrig
    );
        if (!active) return 32'd0;
        return {
            dev_type,
            12'd0,
            start_b,
            select_b,
            r3,
            l3,
            r2 || (rtrig >= 8'd64),
            l2 || (ltrig >= 8'd64),
            r1,
            l1,
            y,
            x,
            b,
            a,
            right,
            left,
            down,
            up
        };
    endfunction

    function automatic logic [31:0] build_joy(
        input logic       active,
        input logic [7:0] lx, ly, rx, ry
    );
        if (!active) return 32'h8080_8080;
        return {joy_u8(ry), joy_u8(rx), joy_u8(ly), joy_u8(lx)};
    endfunction

    function automatic logic [31:0] build_trig(
        input logic       active,
        input logic [7:0] ltrig, rtrig
    );
        if (!active) return 32'd0;
        return {16'd0, rtrig, ltrig};
    endfunction

    logic [31:0] pad_words [0:11];
    always_comb begin
        pad_words[0]  = build_key(input_slots_0_active, input_slots_0_deviceType,
                                  input_slots_0_buttons_up, input_slots_0_buttons_down, input_slots_0_buttons_left, input_slots_0_buttons_right,
                                  input_slots_0_buttons_a, input_slots_0_buttons_b, input_slots_0_buttons_x, input_slots_0_buttons_y,
                                  input_slots_0_buttons_l1, input_slots_0_buttons_r1, input_slots_0_buttons_l2, input_slots_0_buttons_r2,
                                  input_slots_0_buttons_l3, input_slots_0_buttons_r3, input_slots_0_buttons_select, input_slots_0_buttons_start,
                                  input_slots_0_analog_leftTrigger, input_slots_0_analog_rightTrigger);
        pad_words[1]  = build_key(input_slots_1_active, input_slots_1_deviceType,
                                  input_slots_1_buttons_up, input_slots_1_buttons_down, input_slots_1_buttons_left, input_slots_1_buttons_right,
                                  input_slots_1_buttons_a, input_slots_1_buttons_b, input_slots_1_buttons_x, input_slots_1_buttons_y,
                                  input_slots_1_buttons_l1, input_slots_1_buttons_r1, input_slots_1_buttons_l2, input_slots_1_buttons_r2,
                                  input_slots_1_buttons_l3, input_slots_1_buttons_r3, input_slots_1_buttons_select, input_slots_1_buttons_start,
                                  input_slots_1_analog_leftTrigger, input_slots_1_analog_rightTrigger);
        pad_words[2]  = build_key(input_slots_2_active, input_slots_2_deviceType,
                                  input_slots_2_buttons_up, input_slots_2_buttons_down, input_slots_2_buttons_left, input_slots_2_buttons_right,
                                  input_slots_2_buttons_a, input_slots_2_buttons_b, input_slots_2_buttons_x, input_slots_2_buttons_y,
                                  input_slots_2_buttons_l1, input_slots_2_buttons_r1, input_slots_2_buttons_l2, input_slots_2_buttons_r2,
                                  input_slots_2_buttons_l3, input_slots_2_buttons_r3, input_slots_2_buttons_select, input_slots_2_buttons_start,
                                  input_slots_2_analog_leftTrigger, input_slots_2_analog_rightTrigger);
        pad_words[3]  = build_key(input_slots_3_active, input_slots_3_deviceType,
                                  input_slots_3_buttons_up, input_slots_3_buttons_down, input_slots_3_buttons_left, input_slots_3_buttons_right,
                                  input_slots_3_buttons_a, input_slots_3_buttons_b, input_slots_3_buttons_x, input_slots_3_buttons_y,
                                  input_slots_3_buttons_l1, input_slots_3_buttons_r1, input_slots_3_buttons_l2, input_slots_3_buttons_r2,
                                  input_slots_3_buttons_l3, input_slots_3_buttons_r3, input_slots_3_buttons_select, input_slots_3_buttons_start,
                                  input_slots_3_analog_leftTrigger, input_slots_3_analog_rightTrigger);

        pad_words[4]  = build_joy(input_slots_0_active, input_slots_0_analog_leftX, input_slots_0_analog_leftY,
                                  input_slots_0_analog_rightX, input_slots_0_analog_rightY);
        pad_words[5]  = build_joy(input_slots_1_active, input_slots_1_analog_leftX, input_slots_1_analog_leftY,
                                  input_slots_1_analog_rightX, input_slots_1_analog_rightY);
        pad_words[6]  = build_joy(input_slots_2_active, input_slots_2_analog_leftX, input_slots_2_analog_leftY,
                                  input_slots_2_analog_rightX, input_slots_2_analog_rightY);
        pad_words[7]  = build_joy(input_slots_3_active, input_slots_3_analog_leftX, input_slots_3_analog_leftY,
                                  input_slots_3_analog_rightX, input_slots_3_analog_rightY);

        pad_words[8]  = build_trig(input_slots_0_active, input_slots_0_analog_leftTrigger, input_slots_0_analog_rightTrigger);
        pad_words[9]  = build_trig(input_slots_1_active, input_slots_1_analog_leftTrigger, input_slots_1_analog_rightTrigger);
        pad_words[10] = build_trig(input_slots_2_active, input_slots_2_analog_leftTrigger, input_slots_2_analog_rightTrigger);
        pad_words[11] = build_trig(input_slots_3_active, input_slots_3_analog_leftTrigger, input_slots_3_analog_rightTrigger);
    end

    logic [3:0] pad_scan_idx;
    assign apf_pad_clk = clk;
    always_ff @(posedge clk) begin
        if (rst) begin
            pad_scan_idx <= 4'd0;
            apf_pad_we   <= 1'b0;
            apf_pad_wa   <= 4'd0;
            apf_pad_wd   <= 32'd0;
        end else begin
            apf_pad_we   <= 1'b1;
            apf_pad_wa   <= pad_scan_idx;
            apf_pad_wd   <= pad_words[pad_scan_idx];
            pad_scan_idx <= (pad_scan_idx == 4'd11) ? 4'd0 : (pad_scan_idx + 4'd1);
        end
    end

    // =========================================================================
    // 3. VibrateV0 Output
    // =========================================================================
    wire diag_rumble = DIAG_L3_RUMBLE && input_slots_0_active && input_slots_0_buttons_l3;
    assign vibrate_mode = (core_running && core_focused && (rumble_motor_on || diag_rumble)) ? 2'd1 : 2'd0;

    // =========================================================================
    // 4. AudioV0 512-Word Block RAM Ring Buffer & Exact 48,000 Hz Pacer
    //    62,500,000 * 12 / 15,625 = 48,000.000 Hz exact
    // =========================================================================
    (* ram_style = "block" *) logic [31:0] aud_fifo [0:511];
    logic [9:0]  aud_wptr, aud_rptr;
    logic        aud_stale;
    logic [31:0] aud_head;
    logic [13:0] aud_acc;

    wire         aud_clr       = rst || apf_audio_flush || !core_running;
    wire  [9:0]  aud_level     = aud_wptr - aud_rptr;
    wire         aud_full      = aud_level[9]; // level == 512
    wire         aud_out_valid = (aud_level != 10'd0) && !aud_stale;

    wire  [14:0] aud_acc_sum   = {1'b0, aud_acc} + 15'd12;
    wire         aud_tick_48k  = (aud_acc_sum >= 15'd15625);

    wire         aud_push      = !aud_clr && apf_audio_bus_wr && !aud_full;
    wire         aud_pop       = !aud_clr && aud_tick_48k && apf_audio_playback_en && aud_out_valid;
    wire  [9:0]  aud_rptr_next = aud_rptr + {9'd0, aud_pop};

    assign apf_audio_buffer_fill = {2'b00, aud_level};

    always_ff @(posedge clk) begin
        if (rst) begin
            aud_acc <= 14'd0;
        end else begin
            aud_acc <= aud_tick_48k ? 14'(aud_acc_sum - 15'd15625) : aud_acc_sum[13:0];
        end
    end

    always_ff @(posedge clk) begin
        if (aud_clr) begin
            aud_wptr    <= 10'd0;
            aud_rptr    <= 10'd0;
            aud_stale   <= 1'b0;
            audio_left  <= 16'sd0;
            audio_right <= 16'sd0;
        end else begin
            aud_wptr  <= aud_wptr + {9'd0, aud_push};
            aud_rptr  <= aud_rptr_next;
            aud_stale <= aud_push && (aud_wptr[8:0] == aud_rptr_next[8:0]);

            if (!apf_audio_playback_en) begin
                audio_left  <= 16'sd0;
                audio_right <= 16'sd0;
            end else if (aud_tick_48k && aud_out_valid) begin
                audio_left  <= $signed(aud_head[31:16]);
                audio_right <= $signed(aud_head[15:0]);
            end
        end
    end

    // Synchronous BRAM access (separate always_ff without reset for clean RAMB18E1 inference)
    always_ff @(posedge clk) begin
        if (aud_push)
            aud_fifo[aud_wptr[8:0]] <= apf_audio_bus_out;
        aud_head <= aud_fifo[aud_rptr_next[8:0]];
    end

endmodule

`default_nettype wire
