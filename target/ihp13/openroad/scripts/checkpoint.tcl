# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Jannis Schönleber <janniss@iis.ee.ethz.ch>
# - Philippe Sauter   <phsauter@ethz.ch>

# Helper macros to save and load checkpoints
set time [elapsed_run_time]

proc save_checkpoint { checkpoint_name } {
    global save_dir time step_by_step_debug
    utl::report "Saving checkpoint $checkpoint_name"
    set checkpoint ${save_dir}/${checkpoint_name}

    write_def ${checkpoint}.def
    write_verilog ${checkpoint}.v
    write_db ${checkpoint}.odb
    exec zip -j ${checkpoint}.zip ${checkpoint}.def ${checkpoint}.v ${checkpoint}.odb
    file delete ${checkpoint}.def ${checkpoint}.v ${checkpoint}.odb

    set deltaT [expr [elapsed_run_time] - $time]
    set time [elapsed_run_time]
    utl::report "Time: $time sec deltaT: $deltaT"
    if { $step_by_step_debug } {
        utl::report "Pause at checkpoint: $checkpoint_name"
        gui::pause
    }
}

proc load_checkpoint { checkpoint_name } {
    global save_dir
    utl::report "Loading checkpoint $checkpoint_name"
    set checkpoint ${save_dir}/${checkpoint_name}

    # -o (overwrite, no prompt): the staged unattended flow
    # (openspec/changes/ci-pnr-lane/design.md D1) loads a given checkpoint
    # from a fresh openroad process for every stage and every retry -
    # unlike chip.tcl's original single-process usage, which only ever
    # loaded each checkpoint once. Without -o, a second load hits unzip's
    # interactive "replace file?" prompt, which (no stdin in a headless
    # run) reads EOF and silently defaults to skipping the extraction -
    # found via task 2.4's real bring-up.
    exec unzip -o ${checkpoint}.zip -d ${save_dir}/${checkpoint_name}
    read_verilog ${checkpoint}/$checkpoint_name.v
    read_db ${checkpoint}/$checkpoint_name.odb

}

proc load_checkpoint_def { checkpoint_name } {
    global save_dir
    utl::report "Loading checkpoint $checkpoint_name"
    set checkpoint ${save_dir}/${checkpoint_name}

    exec unzip -o ${checkpoint}.zip -d ${save_dir}
    read_verilog ${checkpoint}/$checkpoint_name.v
    read_def ${checkpoint}/$checkpoint_name.def
}