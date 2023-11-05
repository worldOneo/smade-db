#!/bin/bash

total_iterations=16
threads=16 # it appears as that 16 is still insufficient to feed high core count DBs.
connections=12
crusher_thread_range=32-48
port=32781
smade_threads=(1 2 4 6 8 10 12 14 16)

for n in "${smade_threads[@]}"; do
    
    ./main -threads $n -allocator-pages 100000 2>/dev/null &

    sleep 3
    
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port >> "smade - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G >> "smade - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G >> "smade - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R >> "smade - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R >> "smade - $n.txt"
    
    pkill -f "main -threads $n -allocator-pages 100000"

    sleep 3
done


for n in "${smade_threads[@]}"; do
    
    ./main -threads $n -allocator-pages 100000 -affinity-spacing 2 2>/dev/null &

    sleep 3
    
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R >> "smade - $n - 2.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R >> "smade - $n - 2.txt"
    
    pkill -f "./main -threads $n -allocator-pages 100000 -affinity-spacing 2"

    sleep 3
done
port=6700

for n in "${smade_threads[@]}"; do
    args="--num_shards=$n --conn_io_threads=$n"
    dragonfly $args --port 6700 &

    sleep 5
    
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port >> "dragonfly - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G >> "dragonfly - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G >> "dragonfly - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R >> "dragonfly - $n.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R >> "dragonfly - $n.txt"
    
    pkill -f "dragonfly $args --port 6700"

    sleep 5
    rm *.dfs
done

for n in "${smade_threads[@]}"; do
    args="--num_shards=$n --conn_io_threads=$n --proactor_affinity_mode=off"
    dragonfly $args --port 6700 &

    sleep 5
    
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port >> "dragonfly - $n noaffinity.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G >> "dragonfly - $n noaffinity.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G >> "dragonfly - $n noaffinity.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R >> "dragonfly - $n noaffinity.txt"
    taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R >> "dragonfly - $n noaffinity.txt"
    
    pkill -f "dragonfly $args --port 6700"

    sleep 5
    rm *.dfs
done

port=1234
redis-server --port 1234 &

sleep 5

taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port >> "redis.txt"
taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G >> "redis.txt"
taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G >> "redis.txt"
taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 500000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R >> "redis.txt"
taskset -c $crusher_thread_range memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 75000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R >> "redis.txt"

pkill -f "redis-server --port 1234"