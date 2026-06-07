/*
 * bp_fe_tage.sv
 *
 * A simplified TAGE branch predictor designed as a drop-in replacement for 
 * bp_fe_bht.
 */

`include "bp_common_defines.svh"
`include "bp_fe_defines.svh"

module bp_fe_tage
 import bp_common_pkg::*;
 import bp_fe_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)

   , localparam base_idx_width_lp = bht_idx_width_p  // base predictor index width
   , localparam base_els_lp = 2**base_idx_width_lp  // number of entries in the base predictor
   , localparam tage_tables_lp = 4  // number of tagged tables
   , localparam tage_idx_width_lp = (bht_idx_width_p < 8) ? bht_idx_width_p : 8  // index width used by tagged tables
   , localparam tage_els_lp = 2**tage_idx_width_lp  // number of entries in each table
   , localparam tage_tag_width_lp = 8  // tag width
   , localparam provider_width_lp = (tage_tables_lp <= 1) ? 1 : $clog2(tage_tables_lp)  // provider's width
   )
  (input clk_i
   , input                                 reset_i

   , output logic                          init_done_o

   , input                                 w_v_i
   , input                                 w_force_i
   , input [bht_idx_width_p-1:0]           w_idx_i
   , input [bht_offset_width_p-1:0]        w_offset_i
   , input [ghist_width_p-1:0]             w_ghist_i
   , input [bht_row_width_p-1:0]           w_val_i
   , input                                 w_correct_i
   , output logic                          w_yumi_o

   , input                                 r_v_i
   , input [vaddr_width_p-1:0]             r_addr_i
   , input [ghist_width_p-1:0]             r_ghist_i
   , output logic [bht_row_width_p-1:0]    r_val_o
   , output logic                          r_pred_o
   , output logic [bht_idx_width_p-1:0]    r_idx_o
   , output logic [bht_offset_width_p-1:0] r_offset_o
   );

  // ------------------------------------------------------------
  // Storage
  // ------------------------------------------------------------

  logic [1:0] base_ctr [base_els_lp-1:0];  // base predictor table

  logic tage_valid  [tage_tables_lp-1:0][tage_els_lp-1:0];  // valid bit
  logic [tage_tag_width_lp-1:0] tage_tag [tage_tables_lp-1:0][tage_els_lp-1:0];  // tag
  logic [2:0] tage_ctr [tage_tables_lp-1:0][tage_els_lp-1:0];  // 3-bit prediction counter
  logic [1:0] tage_useful [tage_tables_lp-1:0][tage_els_lp-1:0];  // 2-bit usefulness counter

  // ------------------------------------------------------------
  // Initialization
  // ------------------------------------------------------------

  assign init_done_o = ~reset_i;

  integer init_i;
  integer init_t;

  initial begin
    for (init_i = 0; init_i < base_els_lp; init_i = init_i + 1)
      base_ctr[init_i] = 2'b01;  // base predictor iniatialized to weakly not-taken

    for (init_t = 0; init_t < tage_tables_lp; init_t = init_t + 1) begin
      for (init_i = 0; init_i < tage_els_lp; init_i = init_i + 1) begin
        tage_valid [init_t][init_i] = 1'b0;
        tage_tag   [init_t][init_i] = '0;
        tage_ctr   [init_t][init_i] = 3'b011;  // initial prediction counter set to weakly not-taken
        tage_useful[init_t][init_i] = 2'b00;  // initial usefulness counter set to not useful
      end
    end
  end

  // ------------------------------------------------------------
  // Utility functions
  // ------------------------------------------------------------

  // This function returns the smaller integer of two input integers.
  function automatic int min_int(input int a, input int b);
    begin
      min_int = (a < b) ? a : b;
    end
  endfunction

  // This function returns the history length of an tagged table.
  function automatic int hist_len(input int table_id);
    begin
      case (table_id)
        0: hist_len = min_int(2,  ghist_width_p);
        1: hist_len = min_int(4,  ghist_width_p);
        2: hist_len = min_int(6, ghist_width_p);
        default: hist_len = min_int(8, ghist_width_p);
      endcase
    end
  endfunction

  // This function calculates the folded branch history.
  function automatic [tage_idx_width_lp-1:0] fold_hist_idx
    (input [ghist_width_p-1:0] ghist
     , input int hlen
     );
    integer i;
    begin
      fold_hist_idx = '0;
      for (i = 0; i < ghist_width_p; i = i + 1)
        if (i < hlen)
          fold_hist_idx[i % tage_idx_width_lp] =
            fold_hist_idx[i % tage_idx_width_lp] ^ ghist[i];
    end
  endfunction

  // This function calculates the tag.
  function automatic [tage_tag_width_lp-1:0] fold_hist_tag
    (input [ghist_width_p-1:0] ghist
     , input int hlen
     );
    integer i;
    begin
      fold_hist_tag = '0;
      for (i = 0; i < ghist_width_p; i = i + 1)
        if (i < hlen)
          fold_hist_tag[i % tage_tag_width_lp] =
            fold_hist_tag[i % tage_tag_width_lp] ^ ghist[i];
    end
  endfunction

  // This function calculates the tagged table index.
  function automatic [tage_idx_width_lp-1:0] tage_index
    (input [bht_idx_width_p-1:0] idx
     , input [ghist_width_p-1:0] ghist
     , input int table_id
     );
    begin
      tage_index =
        idx[tage_idx_width_lp-1:0]
        ^ fold_hist_idx(ghist, hist_len(table_id))
        ^ tage_idx_width_lp'(table_id * 13);
    end
  endfunction

  // This function calculates the tag for a tagged table entry.
  function automatic [tage_tag_width_lp-1:0] tage_make_tag
    (input [bht_idx_width_p-1:0] idx
     , input [ghist_width_p-1:0] ghist
     , input int table_id
     );
    integer i;
    begin
      tage_make_tag =
        fold_hist_tag(ghist, hist_len(table_id))
        ^ tage_tag_width_lp'(table_id * 29);

      for (i = 0; i < tage_tag_width_lp; i = i + 1)
        if (i < bht_idx_width_p)
          tage_make_tag[i] = tage_make_tag[i] ^ idx[i];
    end
  endfunction

  // This function updates the two-bit prediction counter, saturates at 00 and 11.
  function automatic [1:0] sat_update_2
    (input [1:0] ctr
     , input taken
     );
    begin
      if (taken)
        sat_update_2 = (ctr == 2'b11) ? ctr : ctr + 1'b1;
      else
        sat_update_2 = (ctr == 2'b00) ? ctr : ctr - 1'b1;
    end
  endfunction

  // This function updates the three-bit prediction counter, saturates at 000 and 111.
  function automatic [2:0] sat_update_3
    (input [2:0] ctr
     , input taken
     );
    begin
      if (taken)
        sat_update_3 = (ctr == 3'b111) ? ctr : ctr + 1'b1;
      else
        sat_update_3 = (ctr == 3'b000) ? ctr : ctr - 1'b1;
    end
  endfunction

  // This function returns whether a 3-bit counter is in a weak state (011=weak not taken, 100=weak taken).
  function automatic logic weak_ctr(input [2:0] ctr);
    begin
      weak_ctr = (ctr == 3'b011) | (ctr == 3'b100);
    end
  endfunction

  // ------------------------------------------------------------
  // Read path
  // ------------------------------------------------------------

  wire [bht_idx_width_p-1:0] r_idx_li = r_addr_i[2+:bht_idx_width_p];  // Extract index from virtual address

  wire [bht_offset_width_p-1:0] r_offset_li = r_addr_i[2+bht_idx_width_p+:bht_offset_width_p];  // Extract offset from virtual address

  logic pred_n, alt_pred_n;  // final prediction & alternative prediction
  logic provider_found_n, alt_found_n;  // true if found a prediction & alternative prediction entry
  logic [provider_width_lp-1:0] provider_n;  // the provider table
  logic [bht_row_width_p-1:0] row_n;  // packed output row

  integer rt;
  always_comb begin

    // Start with base predictor as default.
    pred_n = base_ctr[r_idx_li][1];
    alt_pred_n = base_ctr[r_idx_li][1];

    provider_found_n = 1'b0;
    alt_found_n = 1'b0;
    provider_n = '0;

    // Search tables from longest history length to shortest.
    for (rt = tage_tables_lp-1; rt >= 0; rt = rt - 1) begin
      if (tage_valid[rt][tage_index(r_idx_li, r_ghist_i, rt)]
          && (tage_tag[rt][tage_index(r_idx_li, r_ghist_i, rt)]
              == tage_make_tag(r_idx_li, r_ghist_i, rt))) begin

        if (!provider_found_n) begin
          provider_found_n = 1'b1;
          provider_n = provider_width_lp'(rt);
          pred_n = tage_ctr[rt][tage_index(r_idx_li, r_ghist_i, rt)][2];
        end
        else if (!alt_found_n) begin
          alt_found_n = 1'b1;
          alt_pred_n = tage_ctr[rt][tage_index(r_idx_li, r_ghist_i, rt)][2];
        end
      end
    end

    // Alternative prediction selection, used when provider is weak & has zero usefulness.
    if (provider_found_n
        && weak_ctr(tage_ctr[provider_n][tage_index(r_idx_li, r_ghist_i, int'(provider_n))])
        && (tage_useful[provider_n][tage_index(r_idx_li, r_ghist_i, int'(provider_n))] == 2'b00))
      pred_n = alt_pred_n;

    // Pack prediction into BHT row format: valid bit + prediction bit
    row_n = '0;
    row_n[(r_offset_li << 1) + 1] = pred_n;
    row_n[(r_offset_li << 1)]     = 1'b1;
  end

  // Register outputs
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      r_idx_o    <= '0;
      r_offset_o <= '0;
      r_val_o    <= '0;
      r_pred_o   <= 1'b0;
    end
    else if (r_v_i && init_done_o) begin
      r_idx_o    <= r_idx_li;
      r_offset_o <= r_offset_li;
      r_val_o    <= row_n;
      r_pred_o   <= pred_n;
    end
  end

  // ------------------------------------------------------------
  // Update path
  // ------------------------------------------------------------

  wire [`BSG_SAFE_CLOG2(bht_row_width_p)-1:0] w_pred_bit = (w_offset_i << 1'b1) + 1'b1;  // Extract prediction bit

  wire old_pred_taken = w_val_i[w_pred_bit];  // Extract original prediction
  wire actual_taken = w_correct_i ? old_pred_taken : ~old_pred_taken;  // Extract actual outcome

  logic update_provider_found, update_alt_found;  // true if found the provider & alternative during update
  logic [provider_width_lp-1:0] update_provider;  // provider's table id
  logic update_alt_pred;  // alternative prediction

  integer ut;
  always_comb begin
    update_provider_found = 1'b0;
    update_alt_found = 1'b0;
    update_provider = '0;
    update_alt_pred = base_ctr[w_idx_i][1];

    // Search tables from longest to shortest history length
    for (ut = tage_tables_lp-1; ut >= 0; ut = ut - 1) begin
      if (tage_valid[ut][tage_index(w_idx_i, w_ghist_i, ut)]
          && (tage_tag[ut][tage_index(w_idx_i, w_ghist_i, ut)]
              == tage_make_tag(w_idx_i, w_ghist_i, ut))) begin

        if (!update_provider_found) begin
          update_provider_found = 1'b1;
          update_provider = provider_width_lp'(ut);
        end
        else if (!update_alt_found) begin
          update_alt_found = 1'b1;
          update_alt_pred = tage_ctr[ut][tage_index(w_idx_i, w_ghist_i, ut)][2];
        end
      end
    end
  end

  // Allocation a table entry on misprediction
  logic alloc_v;  // allocation valid
  logic [provider_width_lp-1:0] alloc_table;  // the table to allocate
  logic [tage_idx_width_lp-1:0] alloc_idx;  // the index to allocate
  integer alloc_scan;  
  integer provider_int_comb;

  always_comb begin
    alloc_v = 1'b0;
    alloc_table = '0;
    alloc_idx = '0;
    provider_int_comb = update_provider_found ? int'(update_provider) : -1;

    // Search tables from longest to shortest history length, but only tables longer than the provider.
    for (alloc_scan = tage_tables_lp-1; alloc_scan >= 0; alloc_scan = alloc_scan - 1) begin
      if (!alloc_v && (alloc_scan > provider_int_comb)) begin
        if (!tage_valid[alloc_scan][tage_index(w_idx_i, w_ghist_i, alloc_scan)]
            || (tage_useful[alloc_scan][tage_index(w_idx_i, w_ghist_i, alloc_scan)] == 2'b00)) begin
          alloc_v = 1'b1;
          alloc_table = provider_width_lp'(alloc_scan);
          alloc_idx = tage_index(w_idx_i, w_ghist_i, alloc_scan);
        end
      end
    end
  end

  // Single write request per TAGE array. This avoids Verilator NBA crashes.
  logic base_wr_v;  // base predictor write valid
  logic [bht_idx_width_p-1:0] base_wr_idx;  // base predictor write index
  logic [1:0] base_wr_data;  // base predictor write data

  logic tage_valid_wr_v;  // valid array write valid
  logic [provider_width_lp-1:0] tage_valid_wr_table;  // tagged table to write
  logic [tage_idx_width_lp-1:0] tage_valid_wr_idx;  // tagged table index to write
  logic tage_valid_wr_data;  // write data

  logic tage_tag_wr_v;  // tag array write valid
  logic [provider_width_lp-1:0] tage_tag_wr_table;
  logic [tage_idx_width_lp-1:0] tage_tag_wr_idx;
  logic [tage_tag_width_lp-1:0] tage_tag_wr_data;

  logic tage_ctr_wr_v;  // prediction counter array write valid
  logic [provider_width_lp-1:0] tage_ctr_wr_table;
  logic [tage_idx_width_lp-1:0] tage_ctr_wr_idx;
  logic [2:0] tage_ctr_wr_data;

  logic tage_useful_wr_v;  // usefullness array write valid
  logic [provider_width_lp-1:0] tage_useful_wr_table;
  logic [tage_idx_width_lp-1:0] tage_useful_wr_idx;
  logic [1:0] tage_useful_wr_data;

  logic provider_pred;  // provider's prediciton
  logic [tage_idx_width_lp-1:0] provider_idx;  // provider's index

  always_comb begin
    base_wr_v = 1'b0;
    base_wr_idx = w_idx_i;
    base_wr_data = '0;

    tage_valid_wr_v = 1'b0;
    tage_valid_wr_table = '0;
    tage_valid_wr_idx = '0;
    tage_valid_wr_data = 1'b0;

    tage_tag_wr_v = 1'b0;
    tage_tag_wr_table = '0;
    tage_tag_wr_idx = '0;
    tage_tag_wr_data = '0;

    tage_ctr_wr_v = 1'b0;
    tage_ctr_wr_table = '0;
    tage_ctr_wr_idx = '0;
    tage_ctr_wr_data = '0;

    tage_useful_wr_v = 1'b0;
    tage_useful_wr_table = '0;
    tage_useful_wr_idx = '0;
    tage_useful_wr_data = '0;

    provider_pred = 1'b0;
    provider_idx = '0;

    if (init_done_o && w_v_i) begin
      base_wr_v = 1'b1;
      base_wr_data = sat_update_2(base_ctr[w_idx_i], actual_taken);

      // allocate new entry on mispredictions when allocation candidate avaialble.
      if (!w_correct_i && alloc_v) begin
        tage_valid_wr_v = 1'b1;
        tage_valid_wr_table = alloc_table;
        tage_valid_wr_idx = alloc_idx;
        tage_valid_wr_data = 1'b1;

        tage_tag_wr_v = 1'b1;
        tage_tag_wr_table = alloc_table;
        tage_tag_wr_idx = alloc_idx;
        tage_tag_wr_data = tage_make_tag(w_idx_i, w_ghist_i, int'(alloc_table));

        tage_ctr_wr_v = 1'b1;
        tage_ctr_wr_table = alloc_table;
        tage_ctr_wr_idx = alloc_idx;
        tage_ctr_wr_data = actual_taken ? 3'b100 : 3'b011;

        tage_useful_wr_v = 1'b1;
        tage_useful_wr_table = alloc_table;
        tage_useful_wr_idx = alloc_idx;
        tage_useful_wr_data = 2'b00;
      end
      
      // update prediction counter & usefulness counter if provider exists.
      else if (update_provider_found) begin
        provider_idx = tage_index(w_idx_i, w_ghist_i, int'(update_provider));
        provider_pred = tage_ctr[update_provider][provider_idx][2];

        tage_ctr_wr_v = 1'b1;
        tage_ctr_wr_table = update_provider;
        tage_ctr_wr_idx = provider_idx;
        tage_ctr_wr_data = sat_update_3(tage_ctr[update_provider][provider_idx], actual_taken);

        // Update usefulness counter based on provider vs. alternative prediction.
        if (provider_pred != update_alt_pred) begin
          tage_useful_wr_v = 1'b1;
          tage_useful_wr_table = update_provider;
          tage_useful_wr_idx = provider_idx;

          // Increase usefulness counter if provider prediction matches actual outcome, decrease if not.
          if (provider_pred == actual_taken) begin
            tage_useful_wr_data =
              (tage_useful[update_provider][provider_idx] == 2'b11)
              ? 2'b11
              : tage_useful[update_provider][provider_idx] + 1'b1;
          end
          else begin
            tage_useful_wr_data =
              (tage_useful[update_provider][provider_idx] == 2'b00)
              ? 2'b00
              : tage_useful[update_provider][provider_idx] - 1'b1;
          end
        end
      end
    end
  end

  // Update storage arrays
  always_ff @(posedge clk_i) begin
    if (base_wr_v)
      base_ctr[base_wr_idx] <= base_wr_data;

    if (tage_valid_wr_v)
      tage_valid[tage_valid_wr_table][tage_valid_wr_idx] <= tage_valid_wr_data;

    if (tage_tag_wr_v)
      tage_tag[tage_tag_wr_table][tage_tag_wr_idx] <= tage_tag_wr_data;

    if (tage_ctr_wr_v)
      tage_ctr[tage_ctr_wr_table][tage_ctr_wr_idx] <= tage_ctr_wr_data;

    if (tage_useful_wr_v)
      tage_useful[tage_useful_wr_table][tage_useful_wr_idx] <= tage_useful_wr_data;
  end

  assign w_yumi_o = init_done_o & w_v_i;

`ifndef SYNTHESIS
initial begin
  $display("========== USING BP_FE_TAGE ==========");
end
`endif

endmodule