#!/bin/bash

total_iterations=16
threads=16
connections=12
crusher_thread_range=32-63
port=3456
smade_threads=(1 2 4 6 8 10 12 14 16)

for n in "${smade_threads[@]}"; do
    
    ./main -threads $n -allocator-pages 400000 -max-expansions 24 2>/dev/null &

    sleep 5
    for payload in {0..7}; do 
        taskset -c $crusher_thread_range ./loader -threads $threads -connections $connections -port $port -payload $payload >> "smade - $n.txt"
    done

    pkill -f "main -threads $n -allocator-pages 400000"

    sleep 5
done


for n in "${smade_threads[@]}"; do
    
    ./main -threads $n -allocator-pages 400000 -affinity-spacing 2 -max-expansions 24 2>/dev/null &

    sleep 5
    
    for payload in {0..7}; do 
        taskset -c $crusher_thread_range ./loader -threads $threads -connections $connections -port $port -payload $payload >> "smade - $n - 2.txt"
    done
    
    pkill -f "./main -threads $n -allocator-pages 400000 -affinity-spacing 2"

    sleep 5
done
port=6700

for n in "${smade_threads[@]}"; do
    args="--num_shards=$n --conn_io_threads=$n"
    dragonfly $args --port 6700 &

    sleep 5

    for payload in {0..7}; do 
        taskset -c $crusher_thread_range ./loader -threads $threads -connections $connections -port $port -db-type 1 -payload $payload >> "dragonfly - $n.txt"
    done

    pkill -f "dragonfly $args --port 6700"

    sleep 5
    rm *.dfs
done

for n in "${smade_threads[@]}"; do
    args="--num_shards=$n --conn_io_threads=$n --proactor_affinity_mode=off"
    dragonfly $args --port 6700 &

    sleep 5
    
    for payload in {0..7}; do 
        taskset -c $crusher_thread_range ./loader -threads $threads -connections $connections -port $port -db-type 1 -payload $payload >> "dragonfly - $n noaffinity.txt"
    done
    
    pkill -f "dragonfly $args --port 6700"

    sleep 5
    rm *.dfs
done

port=6700
redis-server --port 6700 &

sleep 5
for payload in {0..7}; do 
    taskset -c $crusher_thread_range ./loader -threads $threads -connections $connections -port $port -db-type 1 -payload $payload >> "redis.txt"
done
pkill -f "redis-server --port 6700"