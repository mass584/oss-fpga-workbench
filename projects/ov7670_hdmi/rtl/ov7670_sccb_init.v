// ============================================================================
// OV7670 リセット & SCCB 書き込みシーケンサ
//   3-phase write: [ID=0x42][reg][data]、9bit目(Don't care)は解放
// ============================================================================
module ov7670_sccb_init #(
    parameter CLK_HZ  = 25_200_000,
    parameter SCCB_HZ = 100_000
)(
    input  wire clk,
    input  wire rst,
    output reg  cam_reset_n,
    output reg  sioc,
    output reg  siod_drive_low,   // 1: SIOD を Low に駆動 / 0: 解放(プルアップでHigh)
    output reg  done
);
    localparam TICK_DIV = CLK_HZ / (SCCB_HZ * 4);   // 1bit = 4 tick
    localparam integer TICK_LAST_I = TICK_DIV - 1;
    localparam [15:0]  TICK_LAST   = TICK_LAST_I[15:0];
    reg [15:0] tcnt;
    wire tick = (tcnt == TICK_LAST);
    always @(posedge clk)
        if (rst || tick) tcnt <= 0; else tcnt <= tcnt + 1'b1;

    reg  [7:0]  idx;
    wire [15:0] rom_q;
    ov7670_regs u_rom (.idx(idx), .q(rom_q));   // ov7670_regs.v

    localparam S_PWRUP = 3'd0, S_LOAD = 3'd1, S_START = 3'd2, S_BIT = 3'd3,
               S_STOP  = 3'd4, S_DELAY = 3'd5, S_DONE = 3'd6;

    reg [2:0]  st;
    reg [1:0]  ph;
    reg [4:0]  bitn;
    reg [26:0] sh;
    reg [20:0] dly;          // 2^21 / 25.2MHz ≒ 83ms

    always @(posedge clk) begin
        if (rst) begin
            st <= S_PWRUP; ph <= 0; idx <= 0; dly <= 0; bitn <= 0; sh <= 0;
            cam_reset_n <= 1'b0; sioc <= 1'b1; siod_drive_low <= 1'b0; done <= 1'b0;
        end else begin
            case (st)
            // 電源投入: 前半はRESET=Low、後半はHighにして安定待ち
            S_PWRUP: begin
                dly <= dly + 1'b1;
                if (dly[20]) cam_reset_n <= 1'b1;
                if (&dly) st <= S_LOAD;
            end
            S_LOAD: begin
                if (rom_q == 16'hFFFF) st <= S_DONE;
                else if (rom_q == 16'hFFF0) begin dly <= 0; st <= S_DELAY; end
                else begin
                    sh   <= {8'h42, 1'b1, rom_q[15:8], 1'b1, rom_q[7:0], 1'b1};
                    bitn <= 0; ph <= 0; st <= S_START;
                end
            end
            S_DELAY: begin
                dly <= dly + 1'b1;
                if (&dly) begin idx <= idx + 1'b1; st <= S_LOAD; end
            end
            S_START: if (tick) begin      // SIOC High 中に SIOD を下げる
                case (ph)
                    2'd0: begin siod_drive_low <= 1'b1; ph <= 2'd1; end
                    default: begin sioc <= 1'b0; ph <= 2'd0; st <= S_BIT; end
                endcase
            end
            S_BIT: if (tick) begin
                ph <= ph + 1'b1;
                case (ph)
                    2'd0: siod_drive_low <= ~sh[26];   // SIOC Low 中にデータ変更
                    2'd1: sioc <= 1'b1;
                    2'd2: ;                           // High 保持
                    2'd3: begin
                        sioc <= 1'b0;
                        sh   <= {sh[25:0], 1'b1};
                        bitn <= bitn + 1'b1;
                        if (bitn == 5'd26) st <= S_STOP;
                    end
                endcase
            end
            S_STOP: if (tick) begin       // SIOC High 中に SIOD を上げる
                ph <= ph + 1'b1;
                case (ph)
                    2'd0: siod_drive_low <= 1'b1;
                    2'd1: sioc <= 1'b1;
                    2'd2: siod_drive_low <= 1'b0;
                    2'd3: begin idx <= idx + 1'b1; st <= S_LOAD; end
                endcase
            end
            S_DONE: done <= 1'b1;
            default: st <= S_DONE;
            endcase
        end
    end
endmodule
