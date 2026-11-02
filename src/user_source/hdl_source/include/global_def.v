


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// 2026-09-24: Parenthesize macro expressions: nested integer division used
// to evaluate the refresh interval to zero, disabling periodic refresh.
`define   SDR_CLK_PERIOD                   (1000000000 / 125000000)
// EM638325 requires 4096 AUTO REFRESH commands per 64 ms, independently
// of its 11-bit row address. Use 80% of tREFI to allow a burst to retire.
// At 125 MHz: 1562 clocks = 12.496 us; 3.129 us remain for arbitration.
// This is a clock COUNT (timer resets at COUNT-1), not a terminal index.
`define   SELF_REFRESH_INTERVAL            (((64000000 / 4096 / `SDR_CLK_PERIOD) * 4) / 5)

