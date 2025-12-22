`timescale 1ns/10ps
module video_pll (
	input  wire refclk,
	output wire outclk
);

	altera_pll #(
		.reference_clock_frequency("32.5 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0("32.500000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.pll_type("General"),
		.pll_subtype("General"),
		.pll_auto_reset("On"),
		.pll_bandwidth_preset("Auto")
	) pll_inst (
		.rst(1'b0),
		.outclk(outclk),
		.refclk(refclk)
	);

endmodule
