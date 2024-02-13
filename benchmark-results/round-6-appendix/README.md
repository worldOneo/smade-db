This is an appendix benchmark to clarify that there is no performance difference between having a dbfile and none.
It was run with a crusher version with this script:

```sh
for n in "${smade_threads[@]}"; do
    args="--num_shards=$n --conn_io_threads=$n"
    dragonfly $args --port 6700 &

    sleep 5

    taskset -c $crusher_thread_range ./loader -threads $threads -connections $connections -port $port -db-type 1 -payload 0 >> "dragonfly - $n.txt"
    taskset -c $crusher_thread_range ./loader -threads $threads -connections $connections -port $port -db-type 1 -payload 7 >> "dragonfly - $n.txt"

    pkill -f "dragonfly $args --port 6700"

    sleep 5
    rm *.dfs
done

for n in "${smade_threads[@]}"; do
    args="--num_shards=$n --conn_io_threads=$n --proactor_affinity_mode=off --dbfilename="
    dragonfly $args --port 6700 &

    sleep 5

    taskset -c $crusher_thread_range ./loader -threads $threads -connections $connections -port $port -db-type 1 -payload 0 >> "dragonfly - $n nostore.txt"
    taskset -c $crusher_thread_range ./loader -threads $threads -connections $connections -port $port -db-type 1 -payload 7 >> "dragonfly - $n nostore.txt"

    pkill -f "dragonfly $args --port 6700"

    sleep 5
done
```

and on c7i.16xlarge with `Intel(R) Xeon(R) Platinum 8488C`
