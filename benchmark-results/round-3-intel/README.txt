All tests were performed on AWS `c7i.16xlarge` (64t/32c + 128GB) with `Intel(R) Xeon(R) Platinum 8488C`

Dragonfly for atillery was launched as:
```
dragonfly --num_shards=<dyn> --conn_io_threads=<dyn> --proactor_affinity_mode=off --port=6700
```