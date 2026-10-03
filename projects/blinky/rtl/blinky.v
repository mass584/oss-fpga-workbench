// Blinky: a binary counter shown on active-low LEDs, advancing TICK_HZ times per second.
`timescale 1ns / 1ps
`default_nettype none

// Board facts arrive as `defines from the Makefile (see boards/*.mk).
`ifndef CLK_HZ
`define CLK_HZ 27_000_000
`endif
`ifndef LED_COUNT
`define LED_COUNT 6
`endif

module blinky #(
    parameter integer CLK_HZ    = `CLK_HZ,
    parameter integer TICK_HZ   = 4,
    parameter integer LED_COUNT = `LED_COUNT
) (
    input  wire                 clk,
    input  wire                 rst_n,  // push button, active low
    output wire [LED_COUNT-1:0] led_n   // LEDs, active low
);
    localparam integer DIV = CLK_HZ / TICK_HZ;
    localparam integer W   = $clog2(DIV);
    localparam integer DIV_MAX = DIV - 1;

    // Synchronize the asynchronous button; the design starts in reset after configuration.
    reg [1:0] rst_sync;
    initial rst_sync = 2'b00;  // FPGA power-up value
    always @(posedge clk) rst_sync <= {rst_sync[0], rst_n};
    wire rst = ~rst_sync[1];

    reg [W-1:0]         div_cnt;
    reg [LED_COUNT-1:0] count;

    always @(posedge clk) begin
        if (rst) begin
            div_cnt <= {W{1'b0}};
            count   <= {LED_COUNT{1'b0}};
        end else if (div_cnt == DIV_MAX[W-1:0]) begin
            div_cnt <= {W{1'b0}};
            count   <= count + 1'b1;
        end else begin
            div_cnt <= div_cnt + 1'b1;
        end
    end

    assign led_n = ~count;
endmodule

`default_nettype wire
