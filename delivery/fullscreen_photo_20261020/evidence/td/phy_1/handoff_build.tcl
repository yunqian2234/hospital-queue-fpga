set phyWildParams {route effort routability place seed 1}
source {D:/TD/TD6.2.1/doc/scripts/DefaultFlow.tcl}
fix_hold
update_timing -mode final
report_area -io_info -file {HDMI1.4b_Transmitter_v1.0_phy.area}
report_timing_summary -ep_num 64 -file {final_timing.rpt}
export_db {HDMI1.4b_Transmitter_v1.0_pr.db}
bitgen -bit {HDMI1.4b_Transmitter_v1.0.bit}
export_bitgen_param -file {.bitgen_param.f}
report_timing_summary -ep_num 64 -file {audit_timing.rpt}
report_timing_exception -ep_num 64 -file {audit_exceptions.rpt}
