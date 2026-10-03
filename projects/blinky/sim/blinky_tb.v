// Self-checking testbench for blinky. Fails via $fatal (non-zero exit from vvp).
`timescale 1ns / 1ps
`default_nettype none

module blinky_tb;
    localparam integer CLK_HZ  = 40;  // tiny divider: one tick every 4 clocks
    localparam integer TICK_HZ = 10;
    localparam integer DIV     = CLK_HZ / TICK_HZ;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;
    wire [5:0] led_n;

    blinky #(.CLK_HZ(CLK_HZ), .TICK_HZ(TICK_HZ), .LED_COUNT(6)) dut (
        .clk(clk), .rst_n(rst_n), .led_n(led_n)
    );

    always #5 clk = ~clk;

    reg [1023:0] vcd;
    initial begin
        if ($value$plusargs("vcd=%s", vcd)) begin
            $dumpfile(vcd);
            $dumpvars(0, blinky_tb);
        end
    end

    task automatic expect_count(input [5:0] expected);
        if (led_n !== ~expected)
            $fatal(1, "FAIL t=%0t: led_n=%b expected count=%0d", $time, led_n, expected);
    endtask

    integer i;
    initial begin
        // Held in reset: all LEDs off.
        repeat (5) @(posedge clk);
        #1 expect_count(6'd0);

        // Release reset; after the 2-FF synchronizer the counter runs.
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        for (i = 1; i <= 70; i = i + 1) begin  // covers the 63 -> 0 wrap
            repeat (DIV) @(posedge clk);
            #1 expect_count(i[5:0]);
        end

        // Reset in the middle of counting returns to zero.
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1 expect_count(6'd0);

        $display("PASS: blinky_tb");
        $finish;
    end
endmodule

`default_nettype wire
