// ============================================================================
// BME280 の補正計算と表示文字の生成 (マイクロコード実行器)
//   プログラムは tools/env_asm.py が生成する env_prog.v。命令の意味は env_asm.py の run() と同じ。
//   start で実行を始め (err=1 ならエラー表示のエントリから)、END で止まる (busy=0)。
//   - バイト RAM (センサのレジスタイメージ) を mem_raddr/mem_rdata で読む (読み出しレイテンシ 1)
//   - 表示文字を txt_we/txt_addr/txt_data で書く (txt_addr = 行 * 16 + 桁)
//
//   小さく作るため、ほとんどを逐次処理にしている (1 秒に 1 回、数千クロックで終われば十分):
//   - レジスタファイル r0..r15 (r15 = 除算の余り) は BSRAM (読み出しポート 1 つ)。rs と rt を順に読む
//     (512bit のベクタにして可変の番号で書くと、選択回路だけで LUT が 7000 個を超えた)
//   - プログラム ROM も BSRAM (env_prog.v)
//   - MUL / DIVU / DIV2 は 1 ビットずつ 32 クロック、シフトは 1 ビットずつ imm クロック。
//     DSP は使わない (Apicula 0.33 の gowin_pack は MULT9X9 の属性を扱えず落ちる)
//   - SEXT は 8 / 16 ビットのみ (アセンブラで確認)
// ============================================================================
module env_calc (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire       err,
    output wire       busy,
    output reg  [7:0] mem_raddr,
    input  wire [7:0] mem_rdata,
    output reg        txt_we,
    output reg  [5:0] txt_addr,
    output reg  [4:0] txt_data
);
    localparam [4:0] O_END = 5'd0,  O_LDI = 5'd1,  O_LDB = 5'd2,  O_ADD = 5'd3,  O_SUB = 5'd4,
                     O_MUL = 5'd5,  O_DIVU = 5'd6, O_DIV2 = 5'd7, O_ANDI = 5'd8, O_OR = 5'd9,
                     O_SHL = 5'd10, O_SRA = 5'd11, O_SRL = 5'd12, O_SEXT = 5'd13, O_CLMP = 5'd14,
                     O_PUTC = 5'd15, O_PUTD = 5'd16, O_PUTZ = 5'd17, O_BLK = 5'd18, O_SGN = 5'd19,
                     O_PUTS = 5'd20, O_BNZ = 5'd21;      // 22 = ADDI (既定の分岐で ADD と同じ加算器を使う)
    localparam [4:0] C_SPACE = 5'd10, C_MINUS = 5'd12;     // 文字コード (env_asm.py の CHARS)

    localparam [3:0] S_IDLE = 4'd0, S_F0 = 4'd1, S_F1 = 4'd2, S_RA = 4'd3, S_RB = 4'd4, S_RC = 4'd5,
                     S_EX = 4'd6, S_LD = 4'd7, S_SH = 4'd8, S_MUL = 4'd9, S_DIV = 4'd10, S_WB = 4'd11,
                     S_WB2 = 4'd12;
    reg [3:0] st;
    assign busy = (st != S_IDLE);

    // ---- プログラム ROM (同期読み出し) ----
    reg  [7:0]  pc;
    wire [48:0] rom_q;
    wire [7:0]  err_entry;
    env_prog u_prog (.clk(clk), .addr(pc), .q(rom_q), .err_entry(err_entry));

    reg  [4:0]  op;
    reg  [3:0]  rd, rt;
    reg  [31:0] imm;

    // ---- レジスタファイル (BSRAM, 同期読み出し) ----
    reg         rf_we;
    reg  [3:0]  rf_waddr, rf_raddr;
    reg  [31:0] rf_wdata;
    wire [31:0] rf_rdata;
    dpram #(.DW(32), .AW(4)) u_rf (
        .wclk(clk), .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata),
        .rclk(clk), .raddr(rf_raddr), .rdata(rf_rdata)
    );
    reg  [31:0] va, vb;
    reg         neg, blank;

    // ---- 1 クロックで済む命令 ----
    wire        is_sub = (op == O_SUB);
    wire [31:0] add_b  = (op == O_ADD) ? vb : is_sub ? ~vb : imm;
    wire [31:0] add_q  = va + add_b + {31'd0, is_sub};          // ADD / SUB / ADDI
    reg  [31:0] alu;
    always @* begin
        case (op)
            O_LDI:  alu = imm;
            O_ANDI: alu = va & imm;
            O_OR:   alu = va | vb;
            O_SEXT: alu = imm[4] ? {{16{va[15]}}, va[15:0]} : {{24{va[7]}}, va[7:0]};
            O_CLMP: alu = va[31] ? 32'd0 : (va > imm) ? imm : va;
            O_SGN:  alu = va[31] ? (32'd0 - va) : va;
            default: alu = add_q;
        endcase
    end

    // ---- 複数クロックの命令 ----
    reg  [1:0]  ld_n, ld_i;                     // LDB: 読むバイト数 - 1, 受け取ったバイト数
    reg  [23:0] ld_b;                           // 受け取ったバイト (先に読んだものが上位)
    reg  [31:0] acc, ma, mb;                    // MUL: 部分積の和, 被乗数 (左シフト), 乗数 (右シフト)
    reg  [31:0] dn, dq, dd, drem;               // DIV: 被除数 (左シフト), 商, 除数, 余り (< 除数)
    reg         dpost;                          // DIV2: 商を 2 倍する
    reg  [5:0]  cnt;
    wire [32:0] drem_sh = {drem, dn[31]};
    wire [32:0] drem_sb = drem_sh - {1'b0, dd};
    wire        dge     = !drem_sb[32];         // drem_sh >= dd

    wire [15:0] ld16 = {ld_b[7:0], ld_b[15:8]};            // 2 バイト読み: [addr] (先) が下位
    reg  [31:0] ld_v;
    always @* begin
        case (imm[9:8])
            2'd0:    ld_v = {24'd0, ld_b[7:0]};
            2'd1:    ld_v = {16'd0, ld16};
            2'd2:    ld_v = {{16{ld16[15]}}, ld16};
            default: ld_v = {12'd0, ld_b[23:16], ld_b[15:8], ld_b[7:4]};
        endcase
    end

    always @(posedge clk) begin
        txt_we <= 1'b0;
        rf_we  <= 1'b0;
        if (rst) begin
            st <= S_IDLE; pc <= 8'd0; neg <= 1'b0; blank <= 1'b0;
            op <= O_END; rd <= 4'd0; rt <= 4'd0; imm <= 32'd0; va <= 32'd0; vb <= 32'd0;
            rf_waddr <= 4'd0; rf_raddr <= 4'd0; rf_wdata <= 32'd0;
            mem_raddr <= 8'd0; txt_addr <= 6'd0; txt_data <= 5'd0;
            ld_n <= 2'd0; ld_i <= 2'd0; ld_b <= 24'd0; acc <= 32'd0; ma <= 32'd0; mb <= 32'd0;
            dn <= 32'd0; dq <= 32'd0; dd <= 32'd0; drem <= 32'd0; dpost <= 1'b0; cnt <= 6'd0;
        end else begin
            case (st)
                S_IDLE: if (start) begin pc <= err ? err_entry : 8'd0; st <= S_F0; end
                S_F0: st <= S_F1;                       // ROM が pc を読む
                S_F1: begin
                    {op, rd, rf_raddr, rt, imm} <= rom_q;     // rs はそのままレジスタファイルの読み出し番地へ
                    pc <= pc + 8'd1;
                    st <= S_RA;
                end
                S_RA: begin rf_raddr <= rt; st <= S_RB; end   // rs を読んでいる
                S_RB: begin va <= rf_rdata; st <= S_RC; end   // rt を読んでいる
                S_RC: begin vb <= rf_rdata; st <= S_EX; end
                S_EX: begin
                    st <= S_F0;
                    case (op)
                        O_END: st <= S_IDLE;
                        O_LDB: begin
                            mem_raddr <= imm[7:0];
                            ld_n <= (imm[9:8] == 2'd0) ? 2'd0 : (imm[9:8] == 2'd3) ? 2'd2 : 2'd1;
                            ld_i <= 2'd0; cnt <= 6'd0;
                            st <= S_LD;
                        end
                        O_SHL, O_SRA, O_SRL: begin
                            acc <= va; cnt <= {1'b0, imm[4:0]}; st <= S_SH;
                        end
                        O_MUL: begin
                            acc <= 32'd0; ma <= va; mb <= vb; cnt <= 6'd32; st <= S_MUL;
                        end
                        O_DIVU, O_DIV2: begin
                            dpost <= (op == O_DIV2) && va[31];
                            dn    <= (op == O_DIV2 && !va[31]) ? {va[30:0], 1'b0} : va;
                            dd    <= vb; dq <= 32'd0; drem <= 32'd0; cnt <= 6'd32; st <= S_DIV;
                        end
                        O_PUTC: begin
                            txt_we <= 1'b1; txt_addr <= imm[5:0]; txt_data <= imm[12:8];
                        end
                        O_PUTD, O_PUTZ: begin
                            txt_we <= 1'b1; txt_addr <= imm[5:0];
                            if (op == O_PUTZ && blank && va[3:0] == 4'd0) begin
                                txt_data <= C_SPACE;
                            end else begin
                                txt_data <= {1'b0, va[3:0]};
                                blank    <= 1'b0;
                            end
                        end
                        O_BLK:  blank <= 1'b1;
                        O_PUTS: begin
                            txt_we <= 1'b1; txt_addr <= imm[5:0]; txt_data <= neg ? C_MINUS : C_SPACE;
                        end
                        O_BNZ:  if (va != 32'd0) pc <= imm[7:0];
                        default: begin                  // LDI / ADD / SUB / ADDI / ANDI / OR / SEXT / CLMP / SGN
                            if (op == O_SGN) neg <= va[31];
                            rf_we <= 1'b1; rf_waddr <= rd; rf_wdata <= alu;
                        end
                    endcase
                end
                S_LD: begin
                    // cnt=0: 先頭アドレスを出した直後 (データはまだ)。以降 1 クロックに 1 バイト受け取る
                    cnt <= 6'd1;
                    if (cnt != 6'd0) begin
                        ld_b <= {ld_b[15:0], mem_rdata};
                        ld_i <= ld_i + 2'd1;
                    end
                    if (cnt == 6'd0 || ld_i < ld_n) mem_raddr <= mem_raddr + 8'd1;
                    if (cnt != 6'd0 && ld_i == ld_n) st <= S_WB;
                end
                S_SH: begin
                    if (cnt == 6'd0) st <= S_WB;
                    else begin
                        cnt <= cnt - 6'd1;
                        case (op)
                            O_SHL:   acc <= {acc[30:0], 1'b0};
                            O_SRA:   acc <= {acc[31], acc[31:1]};
                            default: acc <= {1'b0, acc[31:1]};
                        endcase
                    end
                end
                S_MUL: begin
                    if (mb[0]) acc <= acc + ma;
                    ma <= {ma[30:0], 1'b0}; mb <= {1'b0, mb[31:1]}; cnt <= cnt - 6'd1;
                    if (cnt == 6'd1) st <= S_WB;
                end
                S_DIV: begin
                    drem <= dge ? drem_sb[31:0] : drem_sh[31:0];
                    dq   <= {dq[30:0], dge};
                    dn   <= {dn[30:0], 1'b0};
                    cnt  <= cnt - 6'd1;
                    if (cnt == 6'd1) st <= S_WB;
                end
                S_WB: begin
                    st <= S_F0;
                    rf_we <= 1'b1; rf_waddr <= rd;
                    case (op)
                        O_LDB:            rf_wdata <= ld_v;
                        O_DIVU, O_DIV2: begin
                            rf_wdata <= dpost ? {dq[30:0], 1'b0} : dq;
                            st <= S_WB2;
                        end
                        default:          rf_wdata <= acc;     // MUL / シフト
                    endcase
                end
                S_WB2: begin                            // 除算の余り -> r15 (rd=r15 なら余りが残る)
                    rf_we <= 1'b1; rf_waddr <= 4'd15; rf_wdata <= drem;
                    st <= S_F0;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    wire unused_ok = &{1'b0, imm[31:13], drem_sh[32]};
endmodule
