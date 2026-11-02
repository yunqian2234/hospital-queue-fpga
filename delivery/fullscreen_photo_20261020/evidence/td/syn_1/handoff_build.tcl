set synWildParams {gate pack_effort high gate pack_seq_in_io on}
source {D:/TD/TD6.2.1/doc/scripts/DefaultFlow.tcl}
report_timing_summary -ep_num 64 -file {audit_timing.rpt}
report_timing_exception -ep_num 64 -file {audit_exceptions.rpt}
