// ============================================================================
// I2C マスタ (バイト単位のコマンド, オープンドレイン)
//   cmd: 0 = START (繰り返し START 可), 1 = STOP, 2 = WRITE (wdata を送り nack を返す),
//        3 = READ (1 バイト受けて rdata に。mack=1 なら ACK、0 なら NACK を返す)
//   ready=1 のときに cmd_valid を 1 クロック立てる。終わると done が 1 クロック立つ。
//   1 ビットを 4 相 (各 Q クロック) で作る: 相 0 で SDA を変え、1 で SCL を離し、2 で SDA を読み、3 で SCL を下げる
//   scl_low / sda_low = 1 でピンを Low に引く (0 で開放。プルアップは外付け + IO の弱プルアップ)
//   クロックストレッチは扱わない (BME280 は使わない)
// ============================================================================
module i2c_master #(
    parameter integer CLK_HZ = 45_000_000,
    parameter integer I2C_HZ = 100_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       cmd_valid,
    input  wire [1:0] cmd,
    input  wire [7:0] wdata,
    input  wire       mack,
    output wire       ready,
    output reg        done,
    output reg  [7:0] rdata,
    output reg        nack,
    output reg        scl_low,
    output reg        sda_low,
    input  wire       sda_in            // 非同期 (ピン)
);
    localparam integer Q   = CLK_HZ / (4 * I2C_HZ);
    localparam integer QW  = $clog2(Q + 1);
    localparam integer Q_M_I = Q - 1;
    localparam [QW-1:0] Q_M = Q_M_I[QW-1:0];
    localparam [1:0] C_START = 2'd0, C_STOP = 2'd1, C_WRITE = 2'd2, C_READ = 2'd3;

    wire sda_s;
    cdc_sync #(.W(1)) u_sync (.clk(clk), .d(sda_in), .q(sda_s));

    reg          busy;
    reg  [1:0]   c;           // 実行中のコマンド
    reg  [1:0]   ph;          // 相
    reg  [QW-1:0] qc;
    reg  [3:0]   bitn;        // WRITE/READ: 0..7 データ, 8 = ACK
    reg  [7:0]   sh;
    reg          ack_bit;
    assign ready = !busy;

    wire tick = (qc == Q_M);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0; c <= C_START; ph <= 2'd0; qc <= {QW{1'b0}}; bitn <= 4'd0; sh <= 8'd0;
            ack_bit <= 1'b0; rdata <= 8'd0; nack <= 1'b0; scl_low <= 1'b0; sda_low <= 1'b0;
        end else if (!busy) begin
            if (cmd_valid) begin
                busy <= 1'b1; c <= cmd; ph <= 2'd0; qc <= {QW{1'b0}}; bitn <= 4'd0;
                sh <= wdata; ack_bit <= mack;
            end
        end else begin
            qc <= tick ? {QW{1'b0}} : qc + 1'b1;
            if (tick) begin
                ph <= ph + 2'd1;
                case (c)
                    C_START: case (ph)
                        2'd0: sda_low <= 1'b0;                    // SDA を離す (SCL はそのまま)
                        2'd1: scl_low <= 1'b0;                    // SCL を離す
                        2'd2: sda_low <= 1'b1;                    // SCL High 中に SDA を下げる = START
                        default: begin scl_low <= 1'b1; busy <= 1'b0; done <= 1'b1; end
                    endcase
                    C_STOP: case (ph)
                        2'd0: begin scl_low <= 1'b1; sda_low <= 1'b1; end
                        2'd1: scl_low <= 1'b0;
                        2'd2: sda_low <= 1'b0;                    // SCL High 中に SDA を上げる = STOP
                        default: begin busy <= 1'b0; done <= 1'b1; end
                    endcase
                    default: case (ph)                            // WRITE / READ の 1 ビット
                        2'd0: begin
                            scl_low <= 1'b1;
                            if (bitn == 4'd8) sda_low <= (c == C_READ) ? ack_bit : 1'b0;
                            else              sda_low <= (c == C_WRITE) ? ~sh[7] : 1'b0;
                        end
                        2'd1: scl_low <= 1'b0;
                        2'd2: begin
                            if (bitn == 4'd8) begin
                                if (c == C_WRITE) nack <= sda_s;
                            end else begin
                                sh <= {sh[6:0], sda_s};           // WRITE では送ったビットが抜けるだけ
                            end
                        end
                        default: begin
                            scl_low <= 1'b1;
                            bitn <= bitn + 4'd1;
                            if (bitn == 4'd8) begin
                                sda_low <= 1'b0;
                                if (c == C_READ) rdata <= sh;
                                busy <= 1'b0; done <= 1'b1;
                            end
                        end
                    endcase
                endcase
            end
        end
    end
endmodule
