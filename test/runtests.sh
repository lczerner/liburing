#!/bin/bash

TESTS="$@"
RET=0
TIMEOUT=60
DMESG_FILTER="cat"
TEST_DIR=$(dirname $0)
TEST_FILES=""
FAILED=""
SKIPPED=""
MAYBE_FAILED=""
TESTNAME_WIDTH=40

# Only use /dev/kmsg if running as root
DO_KMSG="1"
[ "$(id -u)" != "0" ] && DO_KMSG="0"

# Include config.local if exists and check TEST_FILES for valid devices
if [ -f "$TEST_DIR/config.local" ]; then
	. $TEST_DIR/config.local
	for dev in $TEST_FILES; do
		if [ ! -e "$dev" ]; then
			echo "Test file $dev not valid"
			exit 1
		fi
	done
fi

_check_dmesg()
{
	local dmesg_marker="$1"
	if [ -n "$3" ]; then
		local dmesg_log=$(echo "${2}_${3}.dmesg" | \
				  sed 's/\(\/\|_\/\|\/_\)/_/g')
	else
		local dmesg_log="${2}.dmesg"
	fi

	if [ $DO_KMSG -eq 0 ]; then
		return 0
	fi

	dmesg | bash -c "$DMESG_FILTER" | grep -A 9999 "$dmesg_marker" >"$dmesg_log"
	grep -q -e "kernel BUG at" \
	     -e "WARNING:" \
	     -e "BUG:" \
	     -e "Oops:" \
	     -e "possible recursive locking detected" \
	     -e "Internal error" \
	     -e "INFO: suspicious RCU usage" \
	     -e "INFO: possible circular locking dependency detected" \
	     -e "general protection fault:" \
	     -e "blktests failure" \
	     "$dmesg_log"
	# shellcheck disable=SC2181
	if [[ $? -eq 0 ]]; then
		return 1
	else
		rm -f "$dmesg_log"
		return 0
	fi
}

test_result()
{
	local result=$1
	local logfile=$2
	local test_string=$3
	local msg=$4

	[ -n "$msg" ] && msg="($msg)"

	local RES=""
	local logfile_move=""
	local logmsg=""

	case $result in
		pass)
			RES="OK";;
		skip)
			RES="SKIP"
			SKIPPED="$SKIPPED <$test_string>"
			logfile_move="${logfile}.skipped"
			log_msg="Test ${test_string} skipped"
			;;
		timeout)
			RES="TIMEOUT"
			logfile_move="${logfile}.timeout"
			log_msg="Test $test_name timed out (may not be a failure)"
			;;
		fail)
			RET=1
			RES="FAIL"
			FAILED="$FAILED <$test_string>"
			logfile_move="${logfile}.failed"
			log_msg="Test ${test_string} failed"
			;;
		*)
			echo "Unexpected result"
			exit 1
			;;
	esac

	# Print the result of the test
	printf "\t$RES $msg\n"

	[ "$result" == "pass" ] && return

	# Show the test log in case something went wrong
	if [ -s "${logfile}.log" ]; then
		cat "${logfile}.log" | sed 's/^\(.\)/    \1/'
	fi

	echo "$log_msg $msg" >> ${logfile}.log

	# Rename the log
	[ -n "${logfile_move}" ] && mv ${logfile}.log ${logfile_move}
}

run_test()
{
	local test_name="$1"
	local dev="$2"
	local test_string=$test_name

	# Specify test string to print
	if [ -n "$dev" ]; then
		test_string="$test_name $dev"
	fi

	# Log start of the test
	if [ "$DO_KMSG" -eq 1 ]; then
		local dmesg_marker="Running test $test_string"
		echo $dmesg_marker > /dev/kmsg
		printf "%-${TESTNAME_WIDTH}s" "$test_string"
	else
		local dmesg_marker=""
		printf "%-${TESTNAME_WIDTH}s" "$test_name $dev"
	fi

	# Prepare log file name
	if [ -n "$dev" ]; then
		local logfile=$(echo "${test_name}_${dev}" | \
			    sed 's/\(\/\|_\/\|\/_\)/_/g')
	else
		local logfile=${test_name}
	fi

	# Do we have to exclude the test ?
	echo $TEST_EXCLUDE | grep -w "$test_name" > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		test_skipped "${logfile}" "$test_string" "by user"
		return
	fi

	# Run the test
	timeout --preserve-status -s INT -k $TIMEOUT $TIMEOUT \
		./$test_name $dev > ${logfile}.log 2>&1
	local status=${PIPESTATUS[0]}

	# Check test status
	if [ "$status" -eq 124 ]; then
		test_result timeout "${logfile}" "${test_string}"
	elif [ "$status" -eq 137 ]; then
		test_failed "${logfile}" "${test_string}" "process Killed"
	elif [ "$status" -ne 0 ] && [ "$status" -ne 255 ]; then
		test_result fail "${logfile}" "${test_string}" "status = $status"
	elif ! _check_dmesg "$dmesg_marker" "$test_name" "$dev"; then
		test_result fail "${logfile}" "${test_string}" "dmesg check"
	elif [ "$status" -eq 255 ]; then
		test_result skip "${logfile}" "${test_string}"
	elif [ -n "$dev" ]; then
		sleep .1
		ps aux | grep "\[io_wq_manager\]" > /dev/null
		if [ $? -eq 0 ]; then
			MAYBE_FAILED="$MAYBE_FAILED $test_string"
		fi
		test_result pass "${logfile}" "${test_string}"
	else
		test_result pass "${logfile}" "${test_string}"
	fi

	# Only leave behing log file with some content in it
	if [ ! -s "${logfile}.log" ]; then
		rm -f ${logfile}.log
	fi
}

# Clean up all the logs from previous run
rm -f *.{log,timeout,failed,skipped,dmesg}

# Run all specified tests
for tst in $TESTS; do
	run_test $tst
	if [ ! -z "$TEST_FILES" ]; then
		for dev in $TEST_FILES; do
			run_test $tst $dev
		done
	fi
done

if [ -n "$SKIPPED" ]; then
	echo "Tests skipped: $SKIPPED"
fi

if [ "${RET}" -ne 0 ]; then
	echo "Tests failed: $FAILED"
	exit $RET
else
	sleep 1
	ps aux | grep "\[io_wq_manager\]" > /dev/null
	if [ $? -ne 0 ]; then
		MAYBE_FAILED=""
	fi
	if [ ! -z "$MAYBE_FAILED" ]; then
		echo "Tests _maybe_ failed: $MAYBE_FAILED"
	fi
	echo "All tests passed"
	exit 0
fi
