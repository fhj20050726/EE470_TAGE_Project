/*
 * bp_fe_tage.sv
 *
 * TAGE conditional branch direction predictor.
 * Drop-in replacement for bp_fe_bht.
 */

`include "bp_common_defines.svh"
`include "bp_fe_defines.svh"

module bp_fe_tage
 import bp_common_pkg::*;
 import bp_fe_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)

   , localparam base_idx_width_lp = bht_idx_width_p
   , localparam base_els_lp       = 2**base_idx_width_lp

   , localparam tage_tables_lp    = 4
   , localparam tage_idx_width_lp = (bht_idx_width_p < 8) ? bht_idx_width_p : 8
   , localparam tage_els_lp       = 2**tage_idx_width_lp
   , localparam tage_tag_width_lp = 8
   , localparam provider_width_lp = (tage_tables_lp <= 1) ? 1 : $clog2(tage_tables_lp)
   )
  (input                                   clk_i
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

  logic [1:0] base_ctr [base_els_lp-1:0];

  logic                         tage_valid  [tage_tables_lp-1:0][tage_els_lp-1:0];
  logic [tage_tag_width_lp-1:0] tage_tag    [tage_tables_lp-1:0][tage_els_lp-1:0];
  logic [2:0]                   tage_ctr    [tage_tables_lp-1:0][tage_els_lp-1:0];
  logic [1:0]                   tage_useful [tage_tables_lp-1:0][tage_els_lp-1:0];

  // ------------------------------------------------------------
  // Initialization
  // ------------------------------------------------------------

  enum logic [1:0] {e_reset, e_clear, e_run} state_r, state_n;

  logic [`BSG_WIDTH(base_els_lp)-1:0] init_cnt;

  assign init_done_o = (state_r == e_run);

  always_comb begin
    case (state_r)
      e_clear: state_n = (init_cnt == base_els_lp-1) ? e_run : e_clear;
      e_run:   state_n = e_run;
      default: state_n = e_clear;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (reset_i)
      state_r <= e_reset;
    else
      state_r <= state_n;
  end

  always_ff @(posedge clk_i) begin
    if (reset_i)
      init_cnt <= '0;
    else if (state_r == e_clear)
      init_cnt <= init_cnt + 1'b1;
  end

  integer init_t;
  always_ff @(posedge clk_i) begin
    if (state_r == e_clear) begin
      base_ctr[init_cnt] <= 2'b01;

      if (init_cnt < tage_els_lp) begin
        for (init_t = 0; init_t < tage_tables_lp; init_t = init_t + 1) begin
          tage_valid [init_t][init_cnt] <= 1'b0;
          tage_tag   [init_t][init_cnt] <= '0;
          tage_ctr   [init_t][init_cnt] <= 3'b011;
          tage_useful[init_t][init_cnt] <= 2'b00;
        end
      end
    end
  end

  // ------------------------------------------------------------
  // Utility functions
  // ------------------------------------------------------------

  function automatic int min_int(input int a, input int b);
    begin
      min_int = (a < b) ? a : b;
    end
  endfunction

  function automatic int hist_len(input int table);
    begin
      case (table)
        0: hist_len = min_int(4,  ghist_width_p);
        1: hist_len = min_int(8,  ghist_width_p);
        2: hist_len = min_int(16, ghist_width_p);
        default: hist_len = min_int(32, ghist_width_p);
      endcase
    end
  endfunction

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

  function automatic [tage_idx_width_lp-1:0] tage_index
    (input [bht_idx_width_p-1:0] idx
     , input [ghist_width_p-1:0] ghist
     , input int table
     );
    begin
      tage_index =
        idx[tage_idx_width_lp-1:0]
        ^ fold_hist_idx(ghist, hist_len(table))
        ^ tage_idx_width_lp'(table * 13);
    end
  endfunction

  function automatic [tage_tag_width_lp-1:0] tage_make_tag
    (input [bht_idx_width_p-1:0] idx
     , input [ghist_width_p-1:0] ghist
     , input int table
     );
    integer i;
    begin
      tage_make_tag =
        fold_hist_tag(ghist, hist_len(table))
        ^ tage_tag_width_lp'(table * 29);

      for (i = 0; i < tage_tag_width_lp; i = i + 1)
        if (i < bht_idx_width_p)
          tage_make_tag[i] = tage_make_tag[i] ^ idx[i];
    end
  endfunction

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

  function automatic logic weak_ctr(input [2:0] ctr);
    begin
      weak_ctr = (ctr == 3'b011) | (ctr == 3'b100);
    end
  endfunction

  // ------------------------------------------------------------
  // Read path
  // ------------------------------------------------------------

  wire [bht_idx_width_p-1:0] r_idx_li =
    r_addr_i[2+:bht_idx_width_p];

  wire [bht_offset_width_p-1:0] r_offset_li =
    r_addr_i[2+bht_idx_width_p+:bht_offset_width_p];

  logic pred_n, alt_pred_n, provider_raw_pred_n;
  logic provider_found_n, alt_found_n;
  logic [provider_width_lp-1:0] provider_n, alt_provider_n;
  logic [bht_row_width_p-1:0] row_n;

  integer rt;
  always_comb begin
    pred_n              = base_ctr[r_idx_li][1];
    alt_pred_n          = base_ctr[r_idx_li][1];
    provider_raw_pred_n = base_ctr[r_idx_li][1];

    provider_found_n = 1'b0;
    alt_found_n      = 1'b0;
    provider_n       = '0;
    alt_provider_n   = '0;

    for (rt = tage_tables_lp-1; rt >= 0; rt = rt - 1) begin
      if (tage_valid[rt][tage_index(r_idx_li, r_ghist_i, rt)]
          && (tage_tag[rt][tage_index(r_idx_li, r_ghist_i, rt)]
              == tage_make_tag(r_idx_li, r_ghist_i, rt))) begin

        if (!provider_found_n) begin
          provider_found_n     = 1'b1;
          provider_n           = rt[provider_width_lp-1:0];
          provider_raw_pred_n  = tage_ctr[rt][tage_index(r_idx_li, r_ghist_i, rt)][2];
          pred_n               = provider_raw_pred_n;
        end
        else if (!alt_found_n) begin
          alt_found_n    = 1'b1;
          alt_provider_n = rt[provider_width_lp-1:0];
          alt_pred_n     = tage_ctr[rt][tage_index(r_idx_li, r_ghist_i, rt)][2];
        end
      end
    end

    // Use alternate prediction for newly allocated weak entries.
    if (provider_found_n
        && weak_ctr(tage_ctr[provider_n][tage_index(r_idx_li, r_ghist_i, provider_n)])
        && (tage_useful[provider_n][tage_index(r_idx_li, r_ghist_i, provider_n)] == 2'b00))
      pred_n = alt_pred_n;

    row_n = '0;
    row_n[(r_offset_li << 1) + 1] = pred_n;
    row_n[(r_offset_li << 1)]     = 1'b1;
  end

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

  wire [`BSG_SAFE_CLOG2(bht_row_width_p)-1:0] w_pred_bit =
    (w_offset_i << 1'b1) + 1'b1;

  wire old_pred_taken = w_val_i[w_pred_bit];

  // BlackParrot gives "correct/incorrect"; recover actual branch direction.
  wire actual_taken = w_correct_i ? old_pred_taken : ~old_pred_taken;

  logic update_provider_found, update_alt_found;
  logic [provider_width_lp-1:0] update_provider, update_alt_provider;
  logic update_alt_pred;

  integer ut;
  always_comb begin
    update_provider_found = 1'b0;
    update_alt_found      = 1'b0;
    update_provider       = '0;
    update_alt_provider   = '0;
    update_alt_pred       = base_ctr[w_idx_i][1];

    for (ut = tage_tables_lp-1; ut >= 0; ut = ut - 1) begin
      if (tage_valid[ut][tage_index(w_idx_i, w_ghist_i, ut)]
          && (tage_tag[ut][tage_index(w_idx_i, w_ghist_i, ut)]
              == tage_make_tag(w_idx_i, w_ghist_i, ut))) begin

        if (!update_provider_found) begin
          update_provider_found = 1'b1;
          update_provider       = ut[provider_width_lp-1:0];
        end
        else if (!update_alt_found) begin
          update_alt_found    = 1'b1;
          update_alt_provider = ut[provider_width_lp-1:0];
          update_alt_pred     = tage_ctr[ut][tage_index(w_idx_i, w_ghist_i, ut)][2];
        end
      end
    end
  end

  integer wt;
  integer provider_int;
  logic allocated;
  logic provider_pred;

  always_ff @(posedge clk_i) begin
    if (init_done_o && w_v_i) begin
      base_ctr[w_idx_i] <= sat_update_2(base_ctr[w_idx_i], actual_taken);

      if (update_provider_found) begin
        provider_pred =
          tage_ctr[update_provider][tage_index(w_idx_i, w_ghist_i, update_provider)][2];

        tage_ctr[update_provider][tage_index(w_idx_i, w_ghist_i, update_provider)]
          <= sat_update_3
             (tage_ctr[update_provider][tage_index(w_idx_i, w_ghist_i, update_provider)]
              , actual_taken
              );

        // Useful counter: reward provider only when it disagrees with alt
        // and is correct; punish when it disagrees and is wrong.
        if (provider_pred != update_alt_pred) begin
          if (provider_pred == actual_taken) begin
            if (tage_useful[update_provider][tage_index(w_idx_i, w_ghist_i, update_provider)] != 2'b11)
              tage_useful[update_provider][tage_index(w_idx_i, w_ghist_i, update_provider)]
                <= tage_useful[update_provider][tage_index(w_idx_i, w_ghist_i, update_provider)] + 1'b1;
          end
          else begin
            if (tage_useful[update_provider][tage_index(w_idx_i, w_ghist_i, update_provider)] != 2'b00)
              tage_useful[update_provider][tage_index(w_idx_i, w_ghist_i, update_provider)]
                <= tage_useful[update_provider][tage_index(w_idx_i, w_ghist_i, update_provider)] - 1'b1;
          end
        end
      end

      // Allocate one longer-history entry on mispredict.
      if (!w_correct_i) begin
        allocated = 1'b0;
        provider_int = update_provider_found ? int'(update_provider) : -1;

        for (wt = tage_tables_lp-1; wt >= 0; wt = wt - 1) begin
          if (!allocated && (wt > provider_int)) begin
            if (!tage_valid[wt][tage_index(w_idx_i, w_ghist_i, wt)]
                || (tage_useful[wt][tage_index(w_idx_i, w_ghist_i, wt)] == 2'b00)) begin

              tage_valid [wt][tage_index(w_idx_i, w_ghist_i, wt)] <= 1'b1;
              tage_tag   [wt][tage_index(w_idx_i, w_ghist_i, wt)] <= tage_make_tag(w_idx_i, w_ghist_i, wt);
              tage_ctr   [wt][tage_index(w_idx_i, w_ghist_i, wt)] <= actual_taken ? 3'b100 : 3'b011;
              tage_useful[wt][tage_index(w_idx_i, w_ghist_i, wt)] <= 2'b00;

              allocated = 1'b1;
            end
          end
        end

        // If no entry was available, age useful counters.
        if (!allocated) begin
          for (wt = tage_tables_lp-1; wt >= 0; wt = wt - 1) begin
            if (wt > provider_int) begin
              if (tage_useful[wt][tage_index(w_idx_i, w_ghist_i, wt)] != 2'b00)
                tage_useful[wt][tage_index(w_idx_i, w_ghist_i, wt)]
                  <= tage_useful[wt][tage_index(w_idx_i, w_ghist_i, wt)] - 1'b1;
            end
          end
        end
      end
    end
  end

  assign w_yumi_o = init_done_o & w_v_i;

endmodule
