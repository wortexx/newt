s/\s*req_q <= (store_req_t'.*/      req_q <= (store_req_t'{mode: axi_llc_pkg::tag_mode_e'(2'b0), default: '0});/g
s/module slib_mv_filter #(parameter WIDTH = 4, THRESHOLD = 10).*/module slib_mv_filter #(parameter WIDTH = 4, parameter THRESHOLD = 10) (/g
