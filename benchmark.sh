memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 1000000 --ratio=1:0 --key-minimum=1 --key-maximum=1000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port
memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 1000000 --ratio=1:10 --key-minimum=1 --key-maximum=1000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G
memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 100000 --ratio=1:10 --key-minimum=1 --key-maximum=1000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G
memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 1000000 --ratio=1:10 --key-minimum=1 --key-maximum=1000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R
memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 100000 --ratio=1:10 --key-minimum=1 --key-maximum=1000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R