echo "#######"
echo "*** Test HEAD-only reqests"
curl -I http://localhost:8020/airtalk/airtalk1.mp3

echo "#######"
echo "* Test a byte-range request from an arbitrary, non-zero start point"
curl -I -H "Range:bytes=100-200" http://localhost:8020/airtalk/airtalk1.mp3

echo "#######"
echo "* Test a byte-range request from 0"
curl -I -H "Range:bytes=0-200" http://localhost:8020/airtalk/airtalk1.mp3

echo "#######"
echo "* A byte-range request where the end is higher than the actual file end"
echo "* The range end should be the actual file end"
curl -I -H "Range:bytes=200-9999999999999" http://localhost:8020/airtalk/airtalk1.mp3

echo "#######"
echo "* A byte-range request where the start is higher than the actual file end"
echo "* The range start should be 0"
curl -I -H "Range:bytes=9999999999999-100" http://localhost:8020/airtalk/airtalk1.mp3

echo "*** Test full response requests"
curl http://localhost:8020/airtalk/airtalk1.mp3 > /dev/null
