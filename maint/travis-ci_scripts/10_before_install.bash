#!/bin/bash

source maint/travis-ci_scripts/common.bash
if [[ -n "$SHORT_CIRCUIT_SMOKE" ]] ; then return ; fi

# Different boxes we run on may have different amount of hw threads
# Hence why we need to query
# Originally we used to read /sys/devices/system/cpu/online
# but it is not available these days (odd). Thus we fall to
# the alwas-present /proc/cpuinfo
# The oneliner is a tad convoluted - basicaly what we do is
# slurp the entire file and get the index off the last
# `processor    : XX` line
export NUMTHREADS="$(( $(perl -0777 -n -e 'print (/ (?: .+ ^ processor \s+ : \s+ (\d+) ) (?! ^ processor ) /smx)' < /proc/cpuinfo) + 1 ))"

export CACHE_DIR="/tmp/poormanscache"

# install some common tools from APT, more below unless CLEANTEST
apt_install libapp-nopaste-perl tree apt-transport-https firebird2.5-super firebird2.5-dev tdsodbc libsqliteodbc unixodbc-dev freetds-dev  expect

# FIXME - the debian package is oddly broken - uses a bin/env based shebang
# so nothing works under a brew. Fix here until #debian-perl patches it up
sudo /usr/bin/perl -p -i -e 's|#!/usr/bin/env perl|#!/usr/bin/perl|' $(which nopaste)

if [[ "$CLEANTEST" != "true" ]]; then
### apt-get invocation - faster to grab everything at once
  #

### conig firebird
  # poor man's deb config
  EXPECT_FB_SCRIPT='
    spawn dpkg-reconfigure --frontend=text firebird2.5-super
    expect "Enable Firebird server?"
    send "\177\177\177\177yes\r"
    expect "Password for SYSDBA"
    send "123\r"
    sleep 1
    expect eof
  '
  # creating testdb
  # FIXME - this step still fails from time to time >:(((
  # has to do with the FB reconfiguration I suppose
  # for now if it fails twice - simply skip FB testing
  for i in 1 2 ; do

    run_or_err "Re-configuring Firebird" "
      sync
      DEBIAN_FRONTEND=text sudo expect -c '$EXPECT_FB_SCRIPT'
      sleep 1
      sync
      # restart the server for good measure
      sudo /etc/init.d/firebird2.5-super stop || true
      sleep 1
      sync
      sudo /etc/init.d/firebird2.5-super start
      sleep 1
      sync
    "

    if run_or_err "Creating Firebird TestDB" \
      "echo \"CREATE DATABASE '/var/lib/firebird/2.5/data/dbic_test.fdb';\" | sudo isql-fb -u sysdba -p 123"
    then

      run_or_err "Building FireBird ODBC driver" '
        cd "$(mktemp -d)"
        wget -qO- http://sourceforge.net/projects/firebird/files/firebird-ODBC-driver/2.0.2-Release/OdbcFb-Source-2.0.2.153.gz/download | tar -zx
        cd Builds/Gcc.lin
        perl -p -i -e "s|/usr/lib64|/usr/lib/x86_64-linux-gnu|g" ../makefile.environ
        make -f makefile.linux
        sudo make -f makefile.linux install
      '

      sudo bash -c 'cat >> /etc/odbcinst.ini' <<< "
[Firebird]
Description     = InterBase/Firebird ODBC Driver
Driver          = /usr/lib/x86_64-linux-gnu/libOdbcFb.so
Setup           = /usr/lib/x86_64-linux-gnu/libOdbcFb.so
Threading       = 1
FileUsage       = 1
"

      export DBICTEST_FIREBIRD_DSN=dbi:Firebird:dbname=/var/lib/firebird/2.5/data/dbic_test.fdb
      export DBICTEST_FIREBIRD_USER=SYSDBA
      export DBICTEST_FIREBIRD_PASS=123

      export DBICTEST_FIREBIRD_INTERBASE_DSN=dbi:InterBase:dbname=/var/lib/firebird/2.5/data/dbic_test.fdb
      export DBICTEST_FIREBIRD_INTERBASE_USER=SYSDBA
      export DBICTEST_FIREBIRD_INTERBASE_PASS=123

      export DBICTEST_FIREBIRD_ODBC_DSN="dbi:ODBC:Driver=Firebird;Dbname=/var/lib/firebird/2.5/data/dbic_test.fdb"
      export DBICTEST_FIREBIRD_ODBC_USER=SYSDBA
      export DBICTEST_FIREBIRD_ODBC_PASS=123

      break
    fi

  done
fi
