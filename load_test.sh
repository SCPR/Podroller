#!/bin/sh
#
# run concurrent curls which download from URL to /dev/null.  output total
# and average counts to results directory.
#

# max concurrent curls to kick off
max=50
# how long to sleep between each curl, can be decimal  0.5
delay=5
# url to request from
URL=http://localhost:8020/20120504_airtalk.mp3

RATE=50000


#####
#mkdir -p results
echo > results
while /usr/bin/true
do
count=1
while [ $count -le $max ]
do
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	curl -o /dev/null --limit-rate $RATE -s -w "bytes %{size_download} avg %{speed_download} " "$URL" >> results &
	[ "$delay" != "" ] && sleep $delay
	let count=$count+10
done
wait
done
echo done
