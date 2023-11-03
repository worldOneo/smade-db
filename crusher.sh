#!/bin/bash

total_iterations=16
threads=16 # it appears as that 16 is still insufficient to feed high core count DBs.
connections=12
crusher_thread_range=32-48
port=32781


for ((i=0; i<=16; i+=2)); do
    n=$i
    
    ./main -threads "$n" -allocator-pages 100000 2>/dev/null &

    sleep 3
    
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port >> "smade - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G >> "smade - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 50000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G >> "smade - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R >> "smade - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 50000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R >> "smade - $n.txt"
    
    pkill -f "main -threads $n -allocator-pages 100000"

    sleep 3
done

for ((i=0; i<=16; i+=2)); do
    n=$i
    
    ./main -threads "$n" -allocator-pages 100000 -affinity-spacing 2 2>/dev/null &

    sleep 3
    
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 50000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 50000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R >> "smade - $n - 2.txt"
    
    pkill -f "./main -threads $n -allocator-pages 100000 -affinity-spacing 2"

    sleep 3
done

dragonfly_configs=(
  "--num_shards=1 --conn_io_threads=1",
# 3
  "--num_shards=1 --conn_io_threads=2",
  "--num_shards=2 --conn_io_threads=1",
# 4
  "--num_shards=2 --conn_io_threads=2",
  "--num_shards=3 --conn_io_threads=1",
  "--num_shards=1 --conn_io_threads=3",
# 6
  "--num_shards=3 --conn_io_threads=3",
  "--num_shards=2 --conn_io_threads=4",
  "--num_shards=4 --conn_io_threads=2",
# 8
  "--num_shards=4 --conn_io_threads=4",
  "--num_shards=5 --conn_io_threads=3",
  "--num_shards=3 --conn_io_threads=5",
  "--num_shards=2 --conn_io_threads=6",
# 10
  "--num_shards=5 --conn_io_threads=5",
  "--num_shards=6 --conn_io_threads=4",
  "--num_shards=4 --conn_io_threads=6",
  "--num_shards=3 --conn_io_threads=7",
# 12
  "--num_shards=6 --conn_io_threads=6",
  "--num_shards=8 --conn_io_threads=4",
  "--num_shards=4 --conn_io_threads=8",
  "--num_shards=2 --conn_io_threads=10",
# 14
  "--num_shards=7 --conn_io_threads=7",
  "--num_shards=9 --conn_io_threads=5",
  "--num_shards=5 --conn_io_threads=9",
  "--num_shards=3 --conn_io_threads=11",
# 16
  "--num_shards=8 --conn_io_threads=8",
  "--num_shards=10 --conn_io_threads=6",
  "--num_shards=6 --conn_io_threads=10",
  "--num_shards=4 --conn_io_threads=12",
)

port=6700

for ((i=0; i<${#dragonfly_configs[@]}; i++)); do
    n=$i
    args=${dragonfly_configs[0]}
    dragonfly $args --port 6700 &

    sleep 5
    
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 50000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 50000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R >> "smade - $n - 2.txt"
    
    pkill -f "dragonfly $args --port 6700"

    sleep 5
done