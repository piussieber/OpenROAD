# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, The OpenROAD Authors
#
# debug_route_instance.tcl
#
# A utility script that helps debug detailed routing for a specific instance
# by deleting all signal-net wires connected to it and selectively rerouting
# only those nets.  This is much faster than re-routing the whole design and
# produces focused debug output.
#
# --------------------------------------------------------------------------
# QUICK START
# --------------------------------------------------------------------------
#   # Load the script once (after read_lef / read_def / routing is done):
#   source debug_route_instance.tcl
#
#   # Re-route all signal nets of one instance, with verbose output:
#   debug_route_instance -inst u_cpu/u_alu/add0 -verbose 2
#
#   # Also redo global routing for those nets before detailed routing:
#   debug_route_instance -inst u_cpu/u_alu/add0 -reroute_grt -verbose 2
#
#   # Write DRC violations to a file:
#   debug_route_instance -inst u_cpu/u_alu/add0 -drc_output /tmp/debug.rpt
#
#   # Report wire-length of the affected nets after rerouting:
#   debug_route_instance -inst u_cpu/u_alu/add0 -report_wire_length
#
#   # Limit detailed-routing iterations (useful for quick experiments):
#   debug_route_instance -inst u_cpu/u_alu/add0 -droute_end_iter 10
# --------------------------------------------------------------------------
#
# APPROACH
# --------
#   1.  Find the named instance in the design database.
#   2.  Collect every non-power/non-ground/non-special net attached to it.
#   3.  Print rich debug information about the instance and its nets.
#   4.  Destroy the odb::dbWire of each collected net (removes detailed-route
#       wires while leaving every other net untouched).
#   5.  If -reroute_grt is given: call grt::add_net_to_route + global_route
#       so that fresh route-guides are generated for only those nets.
#   6.  Call detailed_route, which routes only the now-unrouted nets
#       (existing wires on other nets are preserved by TritonRoute).
#   7.  Optionally write DRC violations and/or print wire-length statistics.

# ============================================================
#  Namespace and helpers
# ============================================================
namespace eval ::dri {

# Return the signal-type string for a net
proc sig_type_str { net } {
  return [$net getSigType]
}

# Return 1 if a net should be skipped (power / ground / special)
proc is_power_or_special { net } {
  set sig [$net getSigType]
  if { $sig == "POWER" || $sig == "GROUND" || $sig == "SUPPLY" } {
    return 1
  }
  if { [$net isSpecial] } {
    return 1
  }
  return 0
}

# Return the total path length of a net's detailed-route wire in DBU; 0 if none
proc net_wire_length_dbu { net } {
  set wire [$net getWire]
  if { $wire == "NULL" } {
    return 0
  }
  return [$wire getLength]
}

# Format a DBU value as "x.xx um"
proc fmt_um { dbu scale } {
  if { $dbu <= 0 } {
    return "N/A"
  }
  return [format "%.2f um" [expr { double($dbu) / $scale }]]
}

# ============================================================
#  Main implementation procedure
# ============================================================
proc debug_route_instance_impl { inst_name verbose reroute_grt \
                                  drc_output report_wl dr_end_iter } {

  # ---- 1.  Sanity-check and locate the instance --------------------
  set block [ord::get_db_block]
  if { $block == "NULL" } {
    utl::error GRT 9000 "No design block loaded."
  }

  set inst [$block findInst $inst_name]
  if { $inst == "NULL" } {
    utl::error GRT 9001 "Instance '$inst_name' not found in the design."
  }

  # ---- 2.  Collect signal nets ------------------------------------
  set nets_to_reroute {}
  set seen_net_ids {}

  foreach iterm [$inst getITerms] {
    set net [$iterm getNet]
    if { $net == "NULL" } {
      continue
    }
    # Deduplicate by object ID (a net can appear for multiple pins)
    set net_id [$net getId]
    if { [lsearch -exact $seen_net_ids $net_id] >= 0 } {
      continue
    }
    lappend seen_net_ids $net_id

    if { [::dri::is_power_or_special $net] } {
      if { $verbose >= 2 } {
        puts "  (skip) net '[$net getName]' -- power / ground / special"
      }
      continue
    }
    lappend nets_to_reroute $net
  }

  set n_nets [llength $nets_to_reroute]
  if { $n_nets == 0 } {
    puts "\nINFO: Instance '$inst_name' has no signal nets to reroute."
    return
  }

  # ---- 3.  Print instance / net summary ---------------------------
  set master [$inst getMaster]
  set bbox   [$inst getBBox]
  set tech   [ord::get_db_tech]
  set scale  [$tech getDbUnitsPerMicron]

  puts ""
  puts "================================================================"
  puts " debug_route_instance -- '$inst_name'"
  puts "================================================================"
  puts "  Cell type  : [$master getName]"
  puts [format "  Location   : (%d, %d) -- (%d, %d) \[DBU\]" \
        [$bbox xMin] [$bbox yMin] [$bbox xMax] [$bbox yMax]]
  puts [format "             = (%.3f, %.3f) -- (%.3f, %.3f) \[um\]" \
        [expr { double([$bbox xMin]) / $scale }] \
        [expr { double([$bbox yMin]) / $scale }] \
        [expr { double([$bbox xMax]) / $scale }] \
        [expr { double([$bbox yMax]) / $scale }]]
  puts "  Placement  : [$inst getPlacementStatus]"
  puts "  Signal nets: $n_nets"
  puts "----------------------------------------------------------------"

  if { $verbose >= 1 } {
    puts [format "  %-42s %-6s %-8s %-14s %s" \
          "Net name" "Pins" "Has wire" "Wire length" "Sig type"]
    puts "  [string repeat {-} 82]"
    foreach net $nets_to_reroute {
      set wire       [$net getWire]
      set has_wire   [expr { $wire != "NULL" ? "yes" : "no" }]
      set wlen_dbu   [::dri::net_wire_length_dbu $net]
      set wlen_str   [::dri::fmt_um $wlen_dbu $scale]
      set n_pins     [expr { [llength [$net getITerms]] \
                              + [llength [$net getBTerms]] }]
      puts [format "  %-42s %-6d %-8s %-14s %s" \
            [$net getName] $n_pins $has_wire $wlen_str \
            [::dri::sig_type_str $net]]
    }
    puts "  [string repeat {-} 82]"
  }

  # ---- 4.  Destroy detailed-route wires ---------------------------
  set n_destroyed 0
  puts ""
  puts "Step 1 -- Removing detailed-route wires ..."
  foreach net $nets_to_reroute {
    set wire [$net getWire]
    if { $wire != "NULL" } {
      if { $verbose >= 2 } {
        set wlen [::dri::net_wire_length_dbu $net]
        puts [format "  Destroying wire for '[$net getName]' (length %s)" \
              [::dri::fmt_um $wlen $scale]]
      }
      odb::dbWire_destroy $wire
      incr n_destroyed
    } else {
      if { $verbose >= 2 } {
        puts "  Net '[$net getName]' had no detailed-route wire -- skipped"
      }
    }
  }
  puts "  -> Destroyed $n_destroyed wire(s)."

  # ---- 5.  Optional: redo global routing for these nets -----------
  if { $reroute_grt } {
    puts ""
    puts "Step 2 -- Regenerating global-route guides for affected nets ..."
    foreach net $nets_to_reroute {
      if { $verbose >= 2 } {
        puts "  Adding '[$net getName]' to GRT net list"
      }
      grt::add_net_to_route $net
    }
    if { $verbose >= 1 } {
      global_route -verbose
    } else {
      global_route
    }
    puts "  -> Global routing done."
  } else {
    puts ""
    puts "Step 2 -- Skipping global routing (existing route guides will be used)."
    puts "  Tip: use -reroute_grt to also regenerate global-route guides."
  }

  # ---- 6.  Detailed routing ----------------------------------------
  puts ""
  puts "Step 3 -- Running detailed routing ..."
  puts "  TritonRoute will route only the $n_nets net(s) without wires."

  # Enable per-net DRT debug output for all rerouted nets when verbose >= 2
  if { $verbose >= 2 && $n_nets > 0 } {
    set first_net [lindex $nets_to_reroute 0]
    puts "  (DRT debug) enabling maze/DR debug for net '[$first_net getName]'"
    detailed_route_debug -dr -maze -net [$first_net getName]
  }

  if { $drc_output != "" } {
    if { $dr_end_iter > 0 } {
      detailed_route \
        -output_drc      $drc_output \
        -droute_end_iter $dr_end_iter \
        -verbose         $verbose
    } else {
      detailed_route \
        -output_drc $drc_output \
        -verbose    $verbose
    }
  } else {
    if { $dr_end_iter > 0 } {
      detailed_route \
        -droute_end_iter $dr_end_iter \
        -verbose         $verbose
    } else {
      detailed_route -verbose $verbose
    }
  }

  # ---- 7.  Post-route statistics -----------------------------------
  if { $report_wl } {
    puts ""
    puts "Post-route wire-length statistics:"
    puts [format "  %-42s %s" "Net name" "Wire length"]
    puts "  [string repeat {-} 58]"
    foreach net $nets_to_reroute {
      set wlen_dbu [::dri::net_wire_length_dbu $net]
      set wlen_str [::dri::fmt_um $wlen_dbu $scale]
      if { $wlen_dbu == 0 } {
        set wlen_str "UNROUTED"
      }
      puts [format "  %-42s %s" [$net getName] $wlen_str]
    }
  }

  puts ""
  puts "================================================================"
  puts " Finished: rerouted $n_nets net(s) for instance '$inst_name'"
  puts "================================================================"
  puts ""
}

} ;# namespace ::dri

# ============================================================
#  Public Tcl command  --  debug_route_instance
# ============================================================

sta::define_cmd_args "debug_route_instance" {
    -inst inst_name
    [-verbose level]
    [-reroute_grt]
    [-drc_output filename]
    [-droute_end_iter iter]
    [-report_wire_length]
}

proc debug_route_instance { args } {
  sta::parse_key_args "debug_route_instance" args \
    keys   { -inst -verbose -drc_output -droute_end_iter } \
    flags  { -reroute_grt -report_wire_length }

  sta::check_argc_eq0 "debug_route_instance" $args

  # -inst is required
  if { ![info exists keys(-inst)] } {
    utl::error GRT 9010 \
      "debug_route_instance: -inst <instance_name> is required."
  }
  set inst_name $keys(-inst)

  # -verbose: 0 = quiet, 1 = normal (default), 2 = detailed debug
  set verbose 1
  if { [info exists keys(-verbose)] } {
    set verbose $keys(-verbose)
    if { $verbose < 0 } { set verbose 0 }
    if { $verbose > 2  } { set verbose 2 }
  }

  # -reroute_grt: also redo global routing for affected nets
  set reroute_grt [info exists flags(-reroute_grt)]

  # -drc_output: write DRC violations to the given file
  set drc_output ""
  if { [info exists keys(-drc_output)] } {
    set drc_output $keys(-drc_output)
  }

  # -droute_end_iter: cap the number of DRT iterations (speed vs. quality)
  set dr_end_iter -1
  if { [info exists keys(-droute_end_iter)] } {
    sta::check_positive_integer "-droute_end_iter" $keys(-droute_end_iter)
    set dr_end_iter $keys(-droute_end_iter)
  }

  # -report_wire_length: print per-net wire-lengths after rerouting
  set report_wl [info exists flags(-report_wire_length)]

  ::dri::debug_route_instance_impl \
    $inst_name $verbose $reroute_grt $drc_output $report_wl $dr_end_iter
}
