#!/bin/bash

if [ "$#" == "0" ]; then echo "Usage: $0 main"; exit 1; fi

PROG=$1
shift
PID=$(pidof $PROG) || (echo "Program not found $PROG"; kill $$)
COUNT=1000000
CONCURRENT=100

PIDSTATFILE=$PROG.$PID.pidstat.txt
TESTFILE=$PROG.$PID.count-$COUNT.concurrent-$CONCURRENT.txt
FINALFILE=$PROG.count-$COUNT.concurrent-$CONCURRENT.txt


pidstat -h -rsu -p $PID 1 > $PIDSTATFILE & 2>/dev/null
sleep 2
ab -n $COUNT -c $CONCURRENT http://127.0.0.1:9999/ 2>&1 > $TESTFILE
killall $PROG
sleep 4
killall pidstat > /dev/null 2>&1
sleep 1
head -3 $PIDSTATFILE >> $TESTFILE
grep -v ^# $PIDSTATFILE | grep -v ^Linux | grep -v ^$ >> $TESTFILE
cp $TESTFILE $FINALFILE
