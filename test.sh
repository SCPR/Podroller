# Test HEAD-only reqests
curl -I http://localhost:8020/airtalk/airtalk1.mp3

# Test byte-range requests
curl -I -H "Range:bytes=100-200" http://localhost:8020/airtalk/airtalk1.mp3

# Test full response requests
curl http://localhost:8020/airtalk/airtalk1.mp3 > /dev/null
