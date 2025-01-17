////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	console.v
//
// Project:	ZBasic, a generic toplevel impl using the full ZipCPU
//
// Purpose:	This core implements a device to control the console channel
//		of the debugging bus.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2015-2019, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
`define	CONSOLE_SETUP	2'b00
`define	CONSOLE_FIFO	2'b01
`define	CONSOLE_RXREG	2'b10
`define	CONSOLE_TXREG	2'b11
module	console(i_clk, i_reset,
		//
		i_wb_cyc, i_wb_stb, i_wb_we, i_wb_addr, i_wb_data,
			o_wb_ack, o_wb_stall, o_wb_data,
		//
		o_console_stb, o_console_data, i_console_busy,
		i_console_stb, i_console_data,
		//
		o_console_rx_int, o_console_tx_int,
		o_console_rxfifo_int, o_console_txfifo_int);
	parameter [3:0]	LGFLEN = 0;
	// Perform a simple/quick bounds check on the log FIFO length, to make
	// sure its within the bounds we can support with our current
	// interface.
	localparam [3:0]	LCLLGFLEN = (LGFLEN == 0)  ? 0
					: ((LGFLEN > 4'ha) ? 4'ha
					: ((LGFLEN < 4'h2) ? 4'h2 : LGFLEN));
	//
	input	wire		i_clk, i_reset;
	// Wishbone inputs
	input	wire		i_wb_cyc, i_wb_stb, i_wb_we;
	input	wire	[1:0]	i_wb_addr;
	input	wire	[31:0]	i_wb_data;
	output	reg		o_wb_ack;
	output	wire		o_wb_stall;
	output	reg	[31:0]	o_wb_data;
	//
	output	wire		o_console_stb;
	output	wire	[6:0]	o_console_data;
	input	wire		i_console_busy;
	//
	input	wire		i_console_stb;
	input	wire	[6:0]	i_console_data;
	//
	output	wire		o_console_rx_int, o_console_tx_int,
				o_console_rxfifo_int, o_console_txfifo_int;

	/////////////////////////////////////////
	//
	//
	// First, the receiver
	//
	//
	/////////////////////////////////////////


	// We place it into a receiver FIFO.
	//
	// Here's the declarations for the wires it needs.
	wire		rx_empty_n, rx_fifo_err;
	wire	[6:0]	rxf_wb_data;
	wire	[15:0]	rxf_status;
	//
	// And here's the FIFO proper.
	//
	generate if (LCLLGFLEN > 0)
	begin : RX_WFIFO
		reg		rxf_wb_read;
		reg		rx_console_reset;
		// Note that the FIFO will be cleared upon any reset---basically
		// any time a reset is requested via the wishbone or from
		// i_reset.
		//
		// The FIFO accepts strobe and data from the receiver.
		// We issue another wire to it (rxf_wb_read), true when we wish
		// to read from the FIFO, and we get our data in rxf_wb_data.
		// The FIFO outputs four status-type values: 1) is it non-empty,
		// 2) is the FIFO over half full, 3) a 16-bit status register,
		// containing info regarding how full the FIFO truly is, and
		// 4) an error indicator.
		ufifo	#(.LGFLEN(LCLLGFLEN), .BW(7), .RXFIFO(1))
			rxfifo(i_clk, (i_reset)||(rx_console_reset),
				i_console_stb, i_console_data,
				rx_empty_n,
				rxf_wb_read, rxf_wb_data,
				rxf_status, rx_fifo_err);
		assign	o_console_rxfifo_int = rxf_status[1];

		// We produce four interrupts.  One of the receive interrupts
		// indicates whether or not the receive FIFO is non-empty.
		// This should wake up the CPU.
		assign	o_console_rx_int = rxf_status[0];

		// If the bus requests that we read from the receive FIFO, we
		// need to tell this to the receive FIFO.  Note that because
		// we are using a clock here, the output from the receive FIFO
		// will necessarily be delayed by an extra clock.
		initial	rxf_wb_read = 1'b0;
		always @(posedge i_clk)
			rxf_wb_read <= (i_wb_stb)
					&&(i_wb_addr[1:0]==`CONSOLE_RXREG)
					&&(!i_wb_we);

		initial	rx_console_reset = 1'b1;
		always @(posedge i_clk)
			if ((i_reset)||((i_wb_stb)&&(i_wb_addr[1:0]==`CONSOLE_SETUP)&&(i_wb_we)))
				// The receiver reset, always set on a master reset
				// request.
				rx_console_reset <= 1'b1;
			else if ((i_wb_stb)&&(i_wb_addr[1:0]==`CONSOLE_RXREG)&&(i_wb_we))
				// Writes to the receive register will command a receive
				// reset anytime bit[12] is set.
				rx_console_reset <= i_wb_data[12];
			else
				rx_console_reset <= 1'b0;
	end else begin : RX_NOFIFO
		reg	[6:0]	r_rx_fifo_data;
		reg		r_rx_fifo_full;
		reg		r_rx_fifo_err;

		initial	r_rx_fifo_full = 1'b0;
		always @(posedge i_clk)
		if (i_console_stb)
			r_rx_fifo_full <= 1'b1;
		else if ((i_wb_stb)&&(i_wb_addr[1:0]==`CONSOLE_RXREG)
					&&(!i_wb_we))
			r_rx_fifo_full <= 1'b0;

		always @(posedge i_clk)
		if (i_console_stb)
			r_rx_fifo_data <= i_console_data;

		always @(posedge i_clk)
		if ((r_rx_fifo_full)&&(i_console_stb))
			r_rx_fifo_err <= 1'b1;
		else if ((i_wb_stb)&&(i_wb_addr[1:0]==`CONSOLE_RXREG))
			r_rx_fifo_err <= 1'b0;

		assign	rx_fifo_err = r_rx_fifo_err;
		assign	rx_empty_n  = r_rx_fifo_full;
		assign	rxf_wb_data  = r_rx_fifo_data;

		assign	o_console_rx_int     = rx_empty_n;
		assign	o_console_rxfifo_int = rx_empty_n;
		assign	rxf_status = { 13'h0, {(3){rx_empty_n} } };
	end endgenerate

	// Finally, we'll construct a 32-bit value from these various wires,
	// to be returned over the bus on any read.  These include the data
	// that would be read from the FIFO, an error indicator set upon
	// reading from an empty FIFO, a break indicator, and the frame and
	// parity error signals.
	wire	[31:0]	wb_rx_data;
	assign	wb_rx_data = { 16'h00,
				3'h0, rx_fifo_err,
				1'b0, 1'b0, 1'b0, !rx_empty_n,
				1'b0, rxf_wb_data};

	/////////////////////////////////////////
	//
	//
	// Then the CONSOLE transmitter
	//
	//
	/////////////////////////////////////////
	wire		tx_empty_n, txf_err;
	wire	[15:0]	txf_status;
	reg		txf_wb_write;
	reg	[6:0]	txf_wb_data;

	generate if (LCLLGFLEN > 0)
	begin : TX_WFIFO
		reg		tx_console_reset;
		// Unlike the receiver which goes from RXCONSOLE -> UFIFO -> WB,
		// the transmitter basically goes WB -> UFIFO -> TXCONSOLE.
		// Hence, to build support for the transmitter, we start with
		// the command to write data into the FIFO.  In this case, we
		// use the act of writing to the CONSOLE_TXREG address as our
		// indication that we wish to write to the FIFO.  Here, we
		// create a write command line, and latch the data for the
		// extra clock that it'll take so that the command and data can
		// be both true on the same clock.
		initial	txf_wb_write = 1'b0;
		always @(posedge i_clk)
		begin
			txf_wb_write <= (i_wb_stb)&&(i_wb_addr == `CONSOLE_TXREG)
						&&(i_wb_we);
			txf_wb_data  <= i_wb_data[6:0];
		end

		// Transmit FIFO
		//
		// Most of this is just wire management.  The TX FIFO is
		// identical in implementation to the RX FIFO (theyre both
		// UFIFOs), but the TX FIFO is fed from the WB and read by the
		// transmitter.  Some key differences to note: we reset the
		// transmitter on any request for a break.  We read from the
		// FIFO any time the CONSOLE transmitter is idle and ... we
		// just set the values (above) for controlling writing into
		// this.
		ufifo	#(.LGFLEN(LGFLEN), .BW(7), .RXFIFO(0))
			txfifo(i_clk, (tx_console_reset),
				txf_wb_write, txf_wb_data,
				tx_empty_n,
				(!i_console_busy)&&(tx_empty_n), o_console_data,
				txf_status, txf_err);

		assign	o_console_stb = tx_empty_n;

		// Let's create two transmit based interrupts from the FIFO for
		// the CPU. The first will be true any time the FIFO has at
		// least one open position within it.
		assign	o_console_tx_int = txf_status[0];
		// The second will be true any time the FIFO is less than half
		// full, allowing us a change to always keep it (near) fully
		// charged.
		assign	o_console_txfifo_int = txf_status[1];

		// TX-Reset logic
		//
		// This is nearly identical to the RX reset logic above.
		// Basically, any time someone writes to bit [12] the
		// transmitter will go through a reset cycle.  Keep bit [12]
		// low, and everything will proceed as normal.
		initial	tx_console_reset = 1'b1;
		always @(posedge i_clk)
			if((i_reset)||((i_wb_stb)&&(i_wb_addr == `CONSOLE_SETUP)&&(i_wb_we)))
				tx_console_reset <= 1'b1;
			else if ((i_wb_stb)&&(i_wb_addr[1:0]==`CONSOLE_TXREG)&&(i_wb_we))
				tx_console_reset <= i_wb_data[12];
			else
				tx_console_reset <= 1'b0;
	end else begin : TX_NOFIFO
		reg		r_txf_err;

		initial	txf_wb_write = 1'b0;
		always @(posedge i_clk)
		begin
			if (i_reset)
				txf_wb_write <= 1'b0;
			else if ((i_wb_stb)&&(i_wb_we)
					&&(i_wb_addr == `CONSOLE_TXREG))
				txf_wb_write <= 1'b1;
			else if (!i_console_busy)
				txf_wb_write <= 1'b0;

			if((i_wb_stb)&&(i_wb_we)&&(!o_console_stb)
					&&(i_wb_addr == `CONSOLE_TXREG))
				txf_wb_data  <= i_wb_data[6:0];
		end

		initial	r_txf_err = 1'b0;
		always @(posedge i_clk)
			if ((i_reset)||((i_wb_stb)&&(i_wb_we)
					&&(i_wb_addr == `CONSOLE_SETUP)))
				r_txf_err <= 1'b0;
			else if ((i_wb_stb)&&(i_wb_we)&&(i_wb_data[12])
					&&(i_wb_addr==`CONSOLE_TXREG))
				r_txf_err <= 1'b0;
			else if((i_wb_stb)&&(i_wb_we)
				&&(i_wb_addr == `CONSOLE_TXREG)
				&&(o_console_stb)&&(i_console_busy))
				r_txf_err <= 1'b1;

		assign	txf_err = r_txf_err;
		assign	o_console_txfifo_int = !txf_wb_write;
		assign	o_console_tx_int     = !txf_wb_write;
		assign	o_console_stb  = txf_wb_write;
		assign	o_console_data = txf_wb_data;
		assign	tx_empty_n     = o_console_stb;
		assign	txf_status     = { 13'h0, {(2){txf_wb_write}},
				!txf_wb_write };
	end endgenerate

	// Now that we are done with the chain, pick some wires for the user
	// to read on any read of the transmit port.
	//
	// This port is different from reading from the receive port, since
	// there are no side effects.  (Reading from the receive port advances
	// the receive FIFO, here only writing to the transmit port advances the
	// transmit FIFO--hence the read values are free for ... whatever.)
	// We choose here to provide information about the transmit FIFO
	// (txf_err, txf_half_full, txf_full_n), as well as our whether or not
	// we are actively transmitting.
	wire	[31:0]	wb_tx_data;
	assign	wb_tx_data = { 16'h00,
				1'b0, txf_status[1:0], txf_err,
				1'b0, o_console_stb, 1'b0,
				(i_console_busy|tx_empty_n),
				1'b0,(i_console_busy|tx_empty_n)?txf_wb_data:7'h0};

	// Each of the FIFO's returns a 16 bit status value.  This value tells
	// us both how big the FIFO is, as well as how much of the FIFO is in
	// use.  Let's merge those two status words together into a word we
	// can use when reading about the FIFO.
	wire	[31:0]	wb_fifo_data;
	assign	wb_fifo_data = { txf_status, rxf_status };

	// You may recall from above that reads take two clocks.  Hence, we
	// need to delay the address decoding for a clock until the data is
	// ready.  We do that here.
	reg	[1:0]	r_wb_addr;
	always @(posedge i_clk)
		r_wb_addr <= i_wb_addr;

	// Likewise, the acknowledgement is delayed by one clock.
	reg	r_wb_ack;
	initial	r_wb_ack = 1'b0;
	always @(posedge i_clk) // We'll ACK in two clocks
		r_wb_ack <= (!i_reset)&&(i_wb_stb);
	initial	o_wb_ack = 1'b0;
	always @(posedge i_clk) // Okay, time to set the ACK
		o_wb_ack <= (!i_reset)&&(r_wb_ack)&&(i_wb_cyc);

	// Finally, set the return data.  This data must be valid on the same
	// clock o_wb_ack is high.  On all other clocks, it is irrelelant--since
	// no one cares, no one is reading it, it gets lost in the mux in the
	// interconnect, etc.  For this reason, we can just simplify our logic.
	always @(posedge i_clk)
		casez(r_wb_addr)
		`CONSOLE_SETUP: o_wb_data <= 32'h0;
		`CONSOLE_FIFO:  o_wb_data <= wb_fifo_data;
		`CONSOLE_RXREG: o_wb_data <= wb_rx_data;
		`CONSOLE_TXREG: o_wb_data <= wb_tx_data;
		endcase

	// This device never stalls.  Sure, it takes two clocks, but they are
	// pipelined, and nothing stalls that pipeline.  (Creates FIFO errors,
	// perhaps, but doesn't stall the pipeline.)  Hence, we can just
	// set this value to zero.
	assign	o_wb_stall = 1'b0;

	// Make verilator happy
	// verilator lint_off UNUSED
	wire	[19+5-1:0]	unused;
	assign	unused = { i_wb_data[31:13], i_wb_data[11:7] };
	// verilator lint_on UNUSED
`ifdef	FORMAL
	reg	f_past_valid;
	initial	f_past_valid = 1'b0;
	always @(posedge i_clk)
		f_past_valid <= 1'b1;

	always @(*)
	if (!f_past_valid)
		assume(i_reset);

	localparam	F_LGDEPTH = 3;

	wire	[F_LGDEPTH-1:0]	f_nreq, f_nack, f_outstanding;

	fwb_slave #( .AW(4),.DW(32), .F_LGDEPTH(F_LGDEPTH),
		.F_MAX_STALL(1), .F_MAX_ACK_DELAY(3)
		) fwb(i_clk, i_reset,
			i_wb_cyc, i_wb_stb, i_wb_we, i_wb_addr, i_wb_data,
					4'hf,
				o_wb_ack, o_wb_stall, o_wb_data, 1'b0,
			f_nreq, f_nack, f_outstanding);


	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))
			&&($past(o_console_stb))&&($past(i_console_busy)))
		assert(($stable(o_console_stb))&&($stable(o_console_data)));

	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_console_stb)))
		assert(o_console_rx_int);

	always @(posedge i_clk)
	if ((f_past_valid)&&(o_console_stb))
		assert(!o_console_tx_int);

	always @(posedge i_clk)
	if ((f_past_valid)&&(!o_console_stb))
		assert((o_console_tx_int)&&(o_console_txfifo_int));

	always @(*)
	if ((!i_reset)&&(i_wb_cyc))
		assert(f_outstanding == o_wb_ack + r_wb_ack);
`endif
endmodule
