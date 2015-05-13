#!/bin/bash
# Copyright (c) 2014, Cloudera, inc.
# Confidential Cloudera Information: Covered by NDA.
#
# This script is invoked from the Jenkins builds to build Kudu
# and run all the unit tests.
#
# Environment variables may be used to customize operation:
#   BUILD_TYPE: Default: DEBUG
#     Maybe be one of ASAN|TSAN|LEAKCHECK|DEBUG|RELEASE|COVERAGE|LINT|CLIENT
#
#   KUDU_ALLOW_SLOW_TESTS   Default: 1
#     Runs the "slow" version of the unit tests. Set to 0 to
#     run the tests more quickly.
#
#   TEST_TMPDIR   Default: /tmp/kudutest-$UID
#     Specifies the temporary directory where tests should write their
#     data. It is expected that following the completion of all tests, this
#     directory is empty (i.e. every test cleaned up after itself).
#
#   RUN_FLAKY_ONLY    Default: 0
#     Only runs tests which have failed recently, if this is 1.
#     Used by the kudu-flaky-tests jenkins build.
#
#   KUDU_FLAKY_TEST_ATTEMPTS  Default: 1
#     If more than 1, will fetch the list of known flaky tests
#     from the kudu-test jenkins job, and allow those tests to
#     be flaky in this build.
#
#   TEST_RESULT_SERVER  Default: none
#     The host:port pair of a server running test_result_server.py.
#     This must be configured for flaky test resistance or test result
#     reporting to work.
#
#   BUILD_JAVA        Default: 1
#     Build and test java code if this is set to 1.

# If a commit messages contains a line that says 'DONT_BUILD', exit
# immediately.
DONT_BUILD=$(git show|egrep '^\s{4}DONT_BUILD$')
if [ "x$DONT_BUILD" != "x" ]; then
    echo "*** Build not requested. Exiting."
    exit 1
fi

set -e
# We pipe our build output to a log file with tee.
# This bash setting ensures that the script exits if the build fails.
set -o pipefail
# gather core dumps
ulimit -c unlimited

BUILD_TYPE=${BUILD_TYPE:-DEBUG}
BUILD_TYPE=$(echo "$BUILD_TYPE" | tr a-z A-Z) # capitalize

# Set up defaults for environment variables.
DEFAULT_ALLOW_SLOW_TESTS=1

# TSAN builds are pretty slow, so don't do SLOW tests unless explicitly
# requested
if [ "$BUILD_TYPE" = "TSAN" ]; then
  DEFAULT_ALLOW_SLOW_TESTS=0
fi

export KUDU_FLAKY_TEST_ATTEMPTS=${KUDU_FLAKY_TEST_ATTEMPTS:-1}
export KUDU_ALLOW_SLOW_TESTS=${KUDU_ALLOW_SLOW_TESTS:-$DEFAULT_ALLOW_SLOW_TESTS}
export KUDU_COMPRESS_TEST_OUTPUT=${KUDU_COMPRESS_TEST_OUTPUT:-1}
BUILD_JAVA=${BUILD_JAVA:-1}
export TEST_TMPDIR=${TEST_TMPDIR:-/tmp/kudutest-$UID}

# Ensure that the test data directory is usable.
mkdir -p "$TEST_TMPDIR"
if [ ! -w "$TEST_TMPDIR" ]; then
  echo "Error: Test output directory ($TEST_TMPDIR) is not writable on $(hostname) by user $(whoami)"
  exit 1
fi

ROOT=$(readlink -f $(dirname "$BASH_SOURCE")/../..)
cd $ROOT

list_flaky_tests() {
  curl -s "http://$TEST_RESULT_SERVER/list_failed_tests?num_days=3&build_pattern=%25kudu-test%25"
  return $?
}

TEST_LOGDIR="$ROOT/build/test-logs"
TEST_DEBUGDIR="$ROOT/build/test-debug"

# Remove testing artifacts from the previous run before we do anything
# else. Otherwise, if we fail during the "build" step, Jenkins will
# archive the test logs from the previous run, thinking they came from
# this run, and confuse us when we look at the failed build.
rm -Rf Testing/Temporary
rm -f build.log
rm -Rf $TEST_LOGDIR
rm -Rf $TEST_DEBUGDIR
rm -rf CMakeCache.txt CMakeFiles src/kudu/*/CMakeFiles

cleanup() {
  echo Cleaning up all build artifacts...
  $ROOT/build-support/jenkins/post-build-clean.sh
}
# If we're running inside Jenkins (the BUILD_ID is set), then install
# an exit handler which will clean up all of our build results.
if [ -n "$BUILD_ID" ]; then
  trap cleanup EXIT
fi

# PATH=<toolchain_stuff>:$PATH
export TOOLCHAIN=/mnt/toolchain/toolchain.sh
if [ -f "$TOOLCHAIN" ]; then
  source $TOOLCHAIN
fi

thirdparty/build-if-necessary.sh

# PATH=<thirdparty_stuff>:<toolchain_stuff>:$PATH
THIRDPARTY_BIN=$(pwd)/thirdparty/installed/bin
export PATH=$THIRDPARTY_BIN:$PATH
export PPROF_PATH=$(pwd)/thirdparty/installed/bin/pprof

# Find the newest version of clang in the PATH and store it in CHOSEN_CLANG.
# This is useful when the clang in THIRDPARTY_BIN is older than another
# clang on the system and the latter provides additional runtime
# functionality (i.e. TSAN).
#
# sort -V does an excellent job of sorting by version strings, though it
# means we must aggregate all the clang candidates up front.
declare -a ALL_CLANGS
for CLANG in $(which -a clang); do
  CLANG_VERSION=$($CLANG -v |& \
                  grep "clang version" | \
                  sed -e 's/.*clang version \([0-9\.]\+\).*/\1/')
  ALL_CLANGS+=($CLANG:$CLANG_VERSION)
done
ALL_CLANGS_STR=$(IFS=$'\n'; echo "${ALL_CLANGS[*]}")
echo "Begin clang candidates"
if [ -n "$ALL_CLANGS_STR" ]; then
  echo "$ALL_CLANGS_STR"
fi
echo "End clang candidates"
CHOSEN_CLANG=$(echo "$ALL_CLANGS_STR" | sort -t ':' -k 2,2 -V | tail -1 | cut -d ':' -f 1)
if [ -n "$CHOSEN_CLANG" ]; then
  echo "Selected $CHOSEN_CLANG as the highest version of clang"
else
  echo "Could not find clang in the system"
  exit 1
fi

# Configure the build
if [ "$BUILD_TYPE" = "ASAN" ]; then
  CC=$CHOSEN_CLANG CXX=$CHOSEN_CLANG++ \
   cmake -DKUDU_USE_ASAN=1 -DKUDU_USE_UBSAN=1 .
  BUILD_TYPE=fastdebug
elif [ "$BUILD_TYPE" = "TSAN" ]; then
  CC=$CHOSEN_CLANG CXX=$CHOSEN_CLANG++ \
   cmake -DKUDU_USE_TSAN=1 .
  BUILD_TYPE=fastdebug
  EXTRA_TEST_FLAGS="$EXTRA_TEST_FLAGS -LE no_tsan"
elif [ "$BUILD_TYPE" = "LEAKCHECK" ]; then
  BUILD_TYPE=release
  export HEAPCHECK=normal
  # Workaround for gperftools issue #497
  export LD_BIND_NOW=1
elif [ "$BUILD_TYPE" = "COVERAGE" ]; then
  DO_COVERAGE=1
  BUILD_TYPE=debug
  cmake -DKUDU_GENERATE_COVERAGE=1 .
  # Reset coverage info from previous runs
  find src -name \*.gcda -o -name \*.gcno -exec rm {} \;
elif [ "$BUILD_TYPE" = "LINT" ]; then
  # Create empty test logs or else Jenkins fails to archive artifacts, which
  # results in the build failing.
  mkdir -p Testing/Temporary
  mkdir -p $TEST_LOGDIR

  cmake .
  make lint | tee $TEST_LOGDIR/lint.log
  exit $?
elif [ "$BUILD_TYPE" = "CLIENT" ]; then
  BUILD_TYPE=debug
  # Older versions of gcc suffer from at least one visibility-related bug
  # such that unexpected symbols are included in the client library.
  #
  # See KUDU-455 for details.
  CC=$CHOSEN_CLANG CXX=$CHOSEN_CLANG++ \
    cmake -DKUDU_EXPORTED_CLIENT=1 .
fi

# Only enable test core dumps for certain build types.
if [ "$BUILD_TYPE" != "ASAN" ]; then
  export KUDU_TEST_ULIMIT_CORE=unlimited
fi

# If we are supposed to be resistant to flaky tests, we need to fetch the
# list of tests to ignore
if [ "$KUDU_FLAKY_TEST_ATTEMPTS" -gt 1 ]; then
  echo Fetching flaky test list...
  export KUDU_FLAKY_TEST_LIST=$ROOT/build/flaky-tests.txt
  mkdir -p $(dirname $KUDU_FLAKY_TEST_LIST)
  echo -n > $KUDU_FLAKY_TEST_LIST
    if [ -n "$TEST_RESULT_SERVER" ] && \
        list_flaky_tests > $KUDU_FLAKY_TEST_LIST ; then
    echo Will retry flaky tests up to $KUDU_FLAKY_TEST_ATTEMPTS times:
    cat $KUDU_FLAKY_TEST_LIST
    echo ----------
  else
    echo Unable to fetch flaky test list. Disabling flaky test resistance.
    export KUDU_FLAKY_TEST_ATTEMPTS=1
  fi
fi

cmake . -DCMAKE_BUILD_TYPE=${BUILD_TYPE}

# our tests leave lots of data lying around, clean up before we run
make clean
if [ -d "$TEST_TMPDIR" ]; then
  rm -Rf $TEST_TMPDIR/*
fi

# actually do the build
NUM_PROCS=$(cat /proc/cpuinfo | grep processor | wc -l)
make -j$NUM_PROCS 2>&1 | tee build.log

# If compilation succeeds, try to run all remaining steps despite any failures.
set +e

# Run tests
export GTEST_OUTPUT="xml:$TEST_LOGDIR/" # Enable JUnit-compatible XML output.
if [ "$RUN_FLAKY_ONLY" == "1" ] ; then
  if [ -z "$TEST_RESULT_SERVER" ]; then
    echo Must set TEST_RESULT_SERVER to use RUN_FLAKY_ONLY
    exit 1
  fi
  echo Running flaky tests only:
  list_flaky_tests | tee build/flaky-tests.txt
  test_regex=$(perl -e '
    chomp(my @lines = <>);
    print join("|", map { "^" . quotemeta($_) . "\$" } @lines);
   ' build/flaky-tests.txt)
  EXTRA_TEST_FLAGS="$EXTRA_TEST_FLAGS -R $test_regex"

  # We don't support detecting java flaky tests at the moment.
  echo Disabling Java build since RUN_FLAKY_ONLY=1
  BUILD_JAVA=0
fi

EXIT_STATUS=0

# Run the C++ unit tests.
ctest -j$NUM_PROCS $EXTRA_TEST_FLAGS || EXIT_STATUS=$?

if [ $EXIT_STATUS != 0 ]; then
  # Tests that crash do not generate JUnit report XML files.
  # We go through and generate a kind of poor-man's version of them in those cases.
  for GTEST_OUTFILE in $TEST_LOGDIR/*.txt.gz; do
    TEST_EXE=$(basename $GTEST_OUTFILE .txt.gz)
    GTEST_XMLFILE="$TEST_LOGDIR/$TEST_EXE.xml"
    if [ ! -f "$GTEST_XMLFILE" ]; then
      echo "JUnit report missing:" \
           "generating fake JUnit report file from $GTEST_OUTFILE and saving it to $GTEST_XMLFILE"
      zcat $GTEST_OUTFILE | $ROOT/build-support/parse_test_failure.py -x > $GTEST_XMLFILE
    fi
  done
fi

# If all tests passed, ensure that they cleaned up their test output.
if [ $EXIT_STATUS == 0 ]; then
  TEST_TMPDIR_CONTENTS=$(ls $TEST_TMPDIR)
  if [ -n "$TEST_TMPDIR_CONTENTS" ]; then
    echo "All tests passed, yet some left behind their test output:"
    for SUBDIR in $TEST_TMPDIR_CONTENTS; do
      echo $SUBDIR
    done
    EXIT_STATUS=1
  fi
fi

if [ "$DO_COVERAGE" == "1" ]; then
  echo Generating coverage report...
  ./thirdparty/gcovr-3.0/scripts/gcovr -r src/  -e '.*\.pb\..*' --xml \
      > build/coverage.xml || EXIT_STATUS=$?
fi

if [ "$BUILD_JAVA" == "1" ]; then
  # Make sure we use JDK7
  export JAVA_HOME=$JAVA7_HOME
  export PATH=$JAVA_HOME/bin:$PATH
  pushd java
  export TSAN_OPTIONS="$TSAN_OPTIONS suppressions=$ROOT/build-support/tsan-suppressions.txt history_size=7"
  set -x
  mvn clean test || EXIT_STATUS=$?
  set +x
  popd
fi

if [ "$HEAPCHECK" = normal ]; then
  FAILED_TESTS=$(zgrep -L -- "WARNING: Perftools heap leak checker is active -- Performance may suffer" build/test-logs/*-test.txt*)
  if [ -n "$FAILED_TESTS" ]; then
    echo "Some tests didn't heap check properly:"
    for FTEST in $FAILED_TESTS; do
      echo $FTEST
    done
    EXIT_STATUS=1
  else
    echo "All tests heap checked properly"
  fi
fi
set -e

exit $EXIT_STATUS
