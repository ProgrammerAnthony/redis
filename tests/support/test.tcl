set ::num_tests 0
set ::num_passed 0
set ::num_failed 0
set ::num_skipped 0
set ::num_aborted 0
set ::tests_failed {}
set ::cur_test ""

proc fail {msg} {
    error "assertion:$msg"
}

proc assert {condition} {
    if {![uplevel 1 [list expr $condition]]} {
        set context "(context: [info frame -1])"
        error "assertion:Expected [uplevel 1 [list subst -nocommands $condition]] $context"
    }
}

proc assert_no_match {pattern value} {
    if {[string match $pattern $value]} {
        set context "(context: [info frame -1])"
        error "assertion:Expected '$value' to not match '$pattern' $context"
    }
}

proc assert_match {pattern value} {
    if {![string match $pattern $value]} {
        set context "(context: [info frame -1])"
        error "assertion:Expected '$value' to match '$pattern' $context"
    }
}

proc assert_failed {expected_err detail} {
     if {$detail ne ""} {
        set detail "(detail: $detail)"
     } else {
        set detail "(context: [info frame -2])"
     }
     error "assertion:$expected_err $detail"
}

proc assert_equal {value expected {detail ""}} {
    if {$expected ne $value} {
        assert_failed "Expected '$value' to be equal to '$expected'" $detail
    }
}

proc assert_lessthan {value expected {detail ""}} {
    if {!($value < $expected)} {
        assert_failed "Expected '$value' to be less than '$expected'" $detail
    }
}

proc assert_lessthan_equal {value expected {detail ""}} {
    if {!($value <= $expected)} {
        assert_failed "Expected '$value' to be less than or equal to '$expected'" $detail
    }
}

proc assert_morethan {value expected {detail ""}} {
    if {!($value > $expected)} {
        assert_failed "Expected '$value' to be more than '$expected'" $detail
    }
}

proc assert_morethan_equal {value expected {detail ""}} {
    if {!($value >= $expected)} {
        assert_failed "Expected '$value' to be more than or equal to '$expected'" $detail
    }
}

proc assert_range {value min max {detail ""}} {
    if {!($value <= $max && $value >= $min)} {
        assert_failed "Expected '$value' to be between to '$min' and '$max'" $detail
    }
}

proc assert_error {pattern code {detail ""}} {
    if {[catch {uplevel 1 $code} error]} {
        assert_match $pattern $error
    } else {
        assert_failed "assertion:Expected an error but nothing was caught" $detail
    }
}

proc assert_encoding {enc key} {
    if {$::ignoreencoding} {
        return
    }
    set val [r object encoding $key]
    assert_match $enc $val
}

proc assert_type {type key} {
    assert_equal $type [r type $key]
}

proc assert_refcount {ref key} {
    set val [r object refcount $key]
    assert_equal $ref $val
}

# Wait for the specified condition to be true, with the specified number of
# max retries and delay between retries. Otherwise the 'elsescript' is
# executed.
proc wait_for_condition {maxtries delay e _else_ elsescript} {
    while {[incr maxtries -1] >= 0} {
        set errcode [catch {uplevel 1 [list expr $e]} result]
        if {$errcode == 0} {
            if {$result} break
        } else {
            return -code $errcode $result
        }
        after $delay
    }
    if {$maxtries == -1} {
        set errcode [catch [uplevel 1 $elsescript] result]
        return -code $errcode $result
    }
}

proc search_pattern_list {value pattern_list} {
    set n 0
    foreach el $pattern_list {
        if {[string length $el] > 0 && [regexp -- $el $value]} {
            return $n
        }
        incr n
    }
    return -1
}

proc test {name code {okpattern undefined} {tags {}}} {
    # abort if test name in skiptests
    if {[search_pattern_list $name $::skiptests] >= 0} {
        incr ::num_skipped
        send_data_packet $::test_server_fd skip $name
        return
    }

    # abort if only_tests was set but test name is not included
    if {[llength $::only_tests] > 0 && [search_pattern_list $name $::only_tests] < 0} {
        incr ::num_skipped
        send_data_packet $::test_server_fd skip $name
        return
    }

    set tags [concat $::tags $tags]
    if {![tags_acceptable $tags err]} {
        incr ::num_aborted
        send_data_packet $::test_server_fd ignore "$name: $err"
        return
    }

    incr ::num_tests
    set details {}
    lappend details "$name in $::curfile"

    # set a cur_test global to be logged into new servers that are spawn
    # and log the test name in all existing servers
    set prev_test $::cur_test
    set ::cur_test "$name in $::curfile"
    if {$::external} {
        catch {
            set r [redis [srv 0 host] [srv 0 port] 0 $::tls]
            catch {
                $r debug log "### Starting test $::cur_test"
            }
            $r close
        }
    } else {
        foreach srv $::servers {
            set stdout [dict get $srv stdout]
            set fd [open $stdout "a+"]
            puts $fd "### Starting test $::cur_test"
            close $fd
        }
    }

    send_data_packet $::test_server_fd testing $name

    if {[catch {set retval [uplevel 1 $code]} error]} {
        set assertion [string match "assertion:*" $error]
        if {$assertion || $::durable} {
            # durable prevents the whole tcl test from exiting on an exception.
            # an assertion is handled gracefully anyway.
            set msg [string range $error 10 end]
            lappend details $msg
            if {!$assertion} {
                lappend details $::errorInfo
            }
            lappend ::tests_failed $details

            incr ::num_failed
            send_data_packet $::test_server_fd err [join $details "\n"]

            if {$::stop_on_failure} {
                puts "Test error (last server port:[srv port], log:[srv stdout]), press enter to teardown the test."
                flush stdout
                gets stdin
            }
        } else {
            # Re-raise, let handler up the stack take care of this.
            error $error $::errorInfo
        }
    } else {
        if {$okpattern eq "undefined" || $okpattern eq $retval || [string match $okpattern $retval]} {
            incr ::num_passed
            send_data_packet $::test_server_fd ok $name
        } else {
            set msg "Expected '$okpattern' to equal or match '$retval'"
            lappend details $msg
            lappend ::tests_failed $details

            incr ::num_failed
            send_data_packet $::test_server_fd err [join $details "\n"]
        }
    }

    if {$::traceleaks} {
        set output [exec leaks redis-server]
        if {![string match {*0 leaks*} $output]} {
            send_data_packet $::test_server_fd err "Detected a memory leak in test '$name': $output"
        }
    }
    set ::cur_test $prev_test
}
